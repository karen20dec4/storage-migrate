### modificat de user v2
#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Storage Migration & Clone Tool  —  GUI v1.0

.DESCRIPTION
    Two operation modes, both with a Windows Forms graphical interface:

    ► Migrare OS   – Migrates a Windows installation to a new disk.
                     Creates a new partition layout (EFI/MSR/OS/Recovery),
                     copies all files with robocopy (backup mode, VSS-safe),
                     then installs the Windows boot manager with bcdboot.

    ► Clonare disc – Sector-by-sector raw disk clone, identical to Linux dd.
                     Works for NTFS, exFAT, USB HDD, NVMe — any disk type.
                     Shows live progress bar, MB/s speed, hh:mm:ss elapsed
                     time and estimated time remaining.

    Features:
      • Windows Forms GUI with buttons — no command-line required
      • Live progress bar  (0–100%)
      • Transfer speed display  (MB/s)
      • Elapsed time  hh:mm:ss
      • Estimated time remaining  hh:mm:ss
      • Dry-Run mode  (simulates — no disk changes)
      • Persistent log file  (C:\ProgramData\storage-migrate-backups\)
      • Auto-elevation to Administrator

.NOTES
    Author  : karen20ced4 + Copilot
    Version : 1.2
    Date    : 2026-03-21
    Repo    : https://github.com/karen20ced4/NVME-Migrate
    Requires: Windows 10 / Windows 11 / Windows Server 2019+
              PowerShell 5.1+  (built into Windows 10/11)
              Administrator privileges  (auto-prompted)

.EXAMPLE
    # Double-click the .ps1, or from an elevated PowerShell prompt:
    Set-ExecutionPolicy -Scope Process Bypass -Force
    .\storage-migrate.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 0 — Version & paths
# ─────────────────────────────────────────────────────────────────────────────
$Script:AppVersion = '1.2'
$Script:AppDate    = '2026-03-22'
# Use ProgramData so the path is consistent when script is run elevated
# (elevation can change $env:USERPROFILE to the built-in Administrator profile)
$Script:LogDir     = Join-Path $env:ProgramData 'storage-migrate-backups'
$Script:LogFile    = Join-Path $Script:LogDir ('migrate-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — Load assemblies early (needed for the elevation MessageBox)
# ─────────────────────────────────────────────────────────────────────────────
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — Admin elevation
# ─────────────────────────────────────────────────────────────────────────────
function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "Acest tool necesita drepturi de Administrator.`n`nRelansezi automat ca Administrator?",
        'Storage Migration Tool  —  Drepturi insuficiente',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        # Use Sysnative virtual folder so that a 32-bit PowerShell process re-launches
        # as 64-bit. Sysnative only exists for 32-bit callers; fall back to System32
        # for 64-bit callers (where System32 already is the real 64-bit directory).
        $psDir = if (Test-Path "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe") {
            "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0"
        } else {
            "$env:SystemRoot\System32\WindowsPowerShell\v1.0"
        }
        Start-Process -FilePath "$psDir\powershell.exe" `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" `
            -Verb RunAs
    }
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — Shared state  (GUI thread  ↔  worker runspace)
# ─────────────────────────────────────────────────────────────────────────────
$sync = [hashtable]::Synchronized(@{
    IsRunning   = $false
    IsCancelled = $false
    IsDone      = $false
    IsSuccess   = $false
    BytesDone   = [long]0
    TotalBytes  = [long]0
    SpeedBps    = [long]0
    StartTime   = [DateTime]::UtcNow
    LastError   = [string]''
    StepName    = [string]''
    Phase       = [string]''          # 'clone' | 'migrate'
    LogQueue    = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')
})

$Script:WorkerPS     = $null
$Script:WorkerHandle = $null
$Script:WorkerRS     = $null

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — Pure helper functions  (no GUI references)
# ─────────────────────────────────────────────────────────────────────────────
function Format-Hms ([long]$totalSeconds) {
    if ($totalSeconds -lt 0) { return '--:--:--' }
    # Cast to [long] before using {D2} format specifier: D requires an integer type.
    # [math]::Floor() returns [double], which makes {0:D2} throw FormatException.
    $h = [long]($totalSeconds / 3600)
    $m = [long](($totalSeconds % 3600) / 60)
    $s = $totalSeconds % 60
    return ('{0:D2}:{1:D2}:{2:D2}' -f $h, $m, $s)
}

function Format-HumanSize ([long]$bytes) {
    if ($bytes -ge 1TB) { return ('{0:F2} TB' -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ('{0:F1} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:F0} MB' -f ($bytes / 1MB)) }
    return ('{0} KB' -f [math]::Round($bytes / 1KB))
}

function Get-AllPhysicalDisks {
    $disks = Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | Sort-Object Index
    foreach ($d in $disks) {
        $sz = if ($d.Size) { [long]$d.Size } else { 0L }
        [PSCustomObject]@{
            Index    = [int]$d.Index
            DeviceId = $d.DeviceID          # \\.\PHYSICALDRIVE0
            Model    = $d.Model.Trim()
            SizeBytes= $sz
            SizeHR   = Format-HumanSize $sz
            BusType  = $d.InterfaceType
            Display  = 'Disk {0}  ─  {1}  ─  {2}' -f $d.Index, (Format-HumanSize $sz), $d.Model.Trim()
        }
    }
}

function Get-DiskPartitionTable ([int]$diskNumber) {
    $rows = @()
    try {
        $parts = Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue
        if (-not $parts) { return $rows }
        foreach ($p in $parts) {
            $vol = $null
            try { $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue } catch {}
            $rows += [PSCustomObject]@{
                '#'       = $p.PartitionNumber
                'Tip'     = $p.Type
                'Marime'  = Format-HumanSize $p.Size
                'Litera'  = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '—' }
                'FS'      = if ($vol) { $vol.FileSystemType } else { '—' }
                'Eticheta'= if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { '' }
            }
        }
    } catch {}
    return $rows
}

function Get-FirstFreeDriverLetter {
    $used = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name) + @('A','B','C','D')
    foreach ($l in [char[]]'EFGHIJKLMNOPQRSTUVWXYZ') {
        if ($l -notin $used) { return [string]$l }
    }
    return $null
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — Background worker: CLONE (raw sector-by-sector)
# ─────────────────────────────────────────────────────────────────────────────
# NOTE: This script block runs inside a separate Runspace.
#       It must be fully self-contained (no references to outer scope functions).
$Script:CloneWorkerScript = {
    param(
        [hashtable] $sync,
        [string]    $srcDeviceId,
        [int]       $dstDiskNumber,
        [string]    $dstDeviceId,
        [int]       $chunkBytes,
        [string]    $logFile
    )

    function WLog ([string]$msg, [string]$lv = 'INFO') {
        $ts   = (Get-Date).ToString('HH:mm:ss')
        $line = "[$ts] [$lv] $msg"
        $sync.LogQueue.Enqueue($line)
        try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
    }
    function FmtHR ([long]$b) {
        if ($b -ge 1TB) { return ('{0:F2} TB' -f ($b/1TB)) }
        if ($b -ge 1GB) { return ('{0:F1} GB' -f ($b/1GB)) }
        if ($b -ge 1MB) { return ('{0:F0} MB' -f ($b/1MB)) }
        return ('{0} KB' -f [math]::Round($b/1KB))
    }

    $sync.Phase   = 'clone'
    $srcStream    = $null
    $dstStream    = $null

    try {
        WLog "Deschid disc sursa: $srcDeviceId"
        $srcStream = [System.IO.File]::Open(
            $srcDeviceId,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)

        # Take target disk offline so Windows releases all volume locks
        WLog "Pun disc destinatie offline (Disk $dstDiskNumber) pentru acces exclusiv scriere..."
        $sync.StepName = 'Pregatire disc destinatie (offline)...'
        try {
            $d = Get-Disk -Number $dstDiskNumber -ErrorAction Stop
            if (-not $d.IsOffline) {
                Set-Disk -Number $dstDiskNumber -IsOffline $true -ErrorAction Stop
            }
            Set-Disk -Number $dstDiskNumber -IsReadOnly $false -ErrorAction SilentlyContinue
            WLog "Disc destinatie pus offline OK."
        } catch {
            WLog "Avertisment: nu am putut pune discul offline — scrisul poate esua daca exista volume montate: $_" 'WARN'
        }

        WLog "Deschid disc destinatie pentru scriere: $dstDeviceId"
        $dstStream = [System.IO.File]::Open(
            $dstDeviceId,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::ReadWrite)

        $buf            = New-Object byte[] $chunkBytes
        $sync.StartTime = [DateTime]::UtcNow
        $sync.BytesDone = 0L

        $lastSpeedTime  = [DateTime]::UtcNow
        $lastSpeedBytes = 0L

        WLog ('Incep clonare: {0} → {1}' -f $srcDeviceId, $dstDeviceId)
        WLog ('Marime totala sursa: {0}' -f (FmtHR $sync.TotalBytes))
        WLog ('Buffer chunk: {0} MB' -f [math]::Round($chunkBytes / 1MB))
        $sync.StepName = 'Clonare sector-by-sector...'

        while ($true) {
            if ($sync.IsCancelled) {
                WLog 'Anulat de utilizator.' 'WARN'
                break
            }

            $read = $srcStream.Read($buf, 0, $buf.Length)
            if ($read -le 0) { break }

            $dstStream.Write($buf, 0, $read)
            $sync.BytesDone += $read

            # Recalculate speed every 2 seconds
            $now     = [DateTime]::UtcNow
            $secDiff = ($now - $lastSpeedTime).TotalSeconds
            if ($secDiff -ge 2.0) {
                $bytesDiff      = $sync.BytesDone - $lastSpeedBytes
                $sync.SpeedBps  = [long]($bytesDiff / $secDiff)
                $lastSpeedTime  = $now
                $lastSpeedBytes = $sync.BytesDone
            }
        }

        if (-not $sync.IsCancelled) {
            $sync.StepName = 'Sincronizare buffere...'
            WLog 'Sincronizare buffere (flush)...'
            $dstStream.Flush()
            WLog 'Clonare finalizata cu succes!' 'OK'
            $sync.IsSuccess = $true
        }

    } catch {
        $sync.LastError = $_.ToString()
        WLog "EROARE FATALA: $_" 'ERROR'
        $sync.IsSuccess = $false
    } finally {
        if ($srcStream) { try { $srcStream.Close(); $srcStream.Dispose() } catch {} }
        if ($dstStream) { try { $dstStream.Flush(); $dstStream.Close(); $dstStream.Dispose() } catch {} }
        # Bring the target disk back online
        try { Set-Disk -Number $dstDiskNumber -IsOffline $false -ErrorAction SilentlyContinue } catch {}
        $sync.IsRunning = $false
        $sync.IsDone    = $true
        WLog 'Worker clone terminat.' 'INFO'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — Background worker: MIGRATE OS
# ─────────────────────────────────────────────────────────────────────────────
$Script:MigrateWorkerScript = {
    param(
        [hashtable] $sync,
        [int]       $srcDiskNumber,
        [int]       $dstDiskNumber,
        [bool]      $isDryRun,
        [string]    $logFile
    )

    function WLog ([string]$msg, [string]$lv = 'INFO') {
        $ts   = (Get-Date).ToString('HH:mm:ss')
        $line = "[$ts] [$lv] $msg"
        $sync.LogQueue.Enqueue($line)
        try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
    }
    function WStep ([string]$name) {
        $sync.StepName = $name
        WLog "═══ $name ═══"
    }
    function FmtHR ([long]$b) {
        if ($b -ge 1TB) { return ('{0:F2} TB' -f ($b/1TB)) }
        if ($b -ge 1GB) { return ('{0:F1} GB' -f ($b/1GB)) }
        if ($b -ge 1MB) { return ('{0:F0} MB' -f ($b/1MB)) }
        return ('{0} KB' -f [math]::Round($b/1KB))
    }
    function Invoke-Proc ([string]$exe, [string[]]$ArgumentList, [switch]$AllowNonZero) {
        # Quote any argument that contains whitespace so ProcessStartInfo.Arguments is valid
        $quotedArgs = $ArgumentList | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
        $cmdStr = "$exe $($quotedArgs -join ' ')"
        WLog "Rulez: $cmdStr"
        if ($isDryRun) { WLog "[DRY-RUN] Nu se executa: $cmdStr" 'DRYRUN'; return 0 }
        $psi                        = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exe
        $psi.Arguments              = $quotedArgs -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardInput  = $true   # prevent interactive stdin hangs
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $p.StandardInput.Close()              # close stdin immediately so no tool waits for input
        # Stream stdout and stderr line-by-line so the GUI log updates in real time.
        # ReadToEndAsync() would buffer all output until process exit (bad for long-running
        # processes like robocopy that can run for hours with no GUI feedback).
        $outDone = $false
        $errDone = $false
        $outTask = $p.StandardOutput.ReadLineAsync()
        $errTask = $p.StandardError.ReadLineAsync()
        while (-not $outDone -or -not $errDone) {
            $progressed = $false
            if (-not $outDone -and $outTask.IsCompleted) {
                $l = $outTask.Result
                if ($null -ne $l) {
                    $t = $l.TrimEnd()
                    # Escape { and } so CheckActionPreference's String.Format cannot misinterpret
                    # Activity IDs or other braced tokens from external tools as format specifiers.
                    if ($t) { WLog ($t -replace '\{', '{{' -replace '\}', '}}') }
                    $outTask = $p.StandardOutput.ReadLineAsync()
                } else { $outDone = $true }
                $progressed = $true
            }
            if (-not $errDone -and $errTask.IsCompleted) {
                $l = $errTask.Result
                if ($null -ne $l) {
                    $t = $l.TrimEnd()
                    if ($t) { WLog ($t -replace '\{', '{{' -replace '\}', '}}') 'WARN' }
                    $errTask = $p.StandardError.ReadLineAsync()
                } else { $errDone = $true }
                $progressed = $true
            }
            if (-not $progressed) { [System.Threading.Thread]::Sleep(100) }
        }
        $p.WaitForExit()
        if (-not $AllowNonZero -and $p.ExitCode -ne 0) {
            throw "Comanda a esuat cu cod $($p.ExitCode): $cmdStr"
        }
        return $p.ExitCode
    }
    function Get-FreeLetter {
        $used = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Name) +
                @('A','B','C','D')
        foreach ($l in [char[]]'EFGHIJKLMNOPQRSTUVWXYZ') {
            if ($l -notin $used) { return [string]$l }
        }
        return $null
    }

    $sync.Phase     = 'migrate'
    $sync.StartTime = [DateTime]::UtcNow
    $tmpEfiLetter   = $null
    $tmpOsLetter    = $null
    $srcTmpLetter   = $null

    try {
        # ── Step 1: Validate ──────────────────────────────────────────────────
        WStep 'Validare discuri si detectare partitii'

        $srcDisk = Get-Disk -Number $srcDiskNumber -ErrorAction Stop
        $dstDisk = Get-Disk -Number $dstDiskNumber -ErrorAction Stop

        WLog ('Sursa:      Disk {0} — {1} — {2}' -f $srcDiskNumber, (FmtHR $srcDisk.Size), $srcDisk.FriendlyName)
        WLog ('Destinatie: Disk {0} — {1} — {2}' -f $dstDiskNumber, (FmtHR $dstDisk.Size), $dstDisk.FriendlyName)

        if ($dstDisk.Size -lt $srcDisk.Size) {
            $srcGB = [math]::Round($srcDisk.Size/1GB, 1)
            $dstGB = [math]::Round($dstDisk.Size/1GB, 1)
            throw "Discul destinatie (${dstGB} GB) este mai mic decat sursa (${srcGB} GB)! Clonarea nu este posibila."
        }

        # Detect source partitions
        $srcParts  = Get-Partition -DiskNumber $srcDiskNumber -ErrorAction Stop | Sort-Object PartitionNumber
        $efiPart   = $srcParts | Where-Object { $_.Type -eq 'System'   } | Select-Object -First 1
        $msrPart   = $srcParts | Where-Object { $_.Type -eq 'Reserved' } | Select-Object -First 1
        $recovPart = $srcParts | Where-Object { $_.Type -eq 'Recovery' } | Select-Object -First 1
        $osPart    = $null

        # Find the OS (C:\) partition
        foreach ($p in ($srcParts | Where-Object { $_.Type -eq 'Basic' })) {
            try {
                $vol = Get-Volume -Partition $p -ErrorAction SilentlyContinue
                if ($vol -and $vol.DriveLetter -eq 'C') { $osPart = $p; break }
            } catch {}
        }
        # Fallback: biggest Basic partition
        if (-not $osPart) {
            $osPart = $srcParts | Where-Object { $_.Type -eq 'Basic' } |
                      Sort-Object Size -Descending | Select-Object -First 1
        }
        if (-not $osPart) {
            throw "Nu am gasit o partitie Windows (C:\) pe Disk $srcDiskNumber. Verifica ca discul sursa contine Windows."
        }

        $isUEFI    = ($srcDisk.PartitionStyle -eq 'GPT') -and ($null -ne $efiPart)
        if ($efiPart)   { $efiSizeMB = [math]::Max(100, [math]::Floor($efiPart.Size   / 1MB)) } else { $efiSizeMB = 100 }
        if ($msrPart)   { $msrSizeMB = [math]::Max(16,  [math]::Floor($msrPart.Size   / 1MB)) } else { $msrSizeMB = 16  }
        if ($recovPart) { $recSizeMB = [math]::Max(500, [math]::Floor($recovPart.Size / 1MB)) } else { $recSizeMB = 0   }
        # Expand OS partition if destination is larger than source
        $extraMB   = [math]::Max(0, [math]::Floor(($dstDisk.Size - $srcDisk.Size) / 1MB))
        $osSizeMB  = [math]::Floor($osPart.Size / 1MB) + $extraMB

        WLog ('Stil boot:          {0}' -f $(if ($isUEFI) { 'UEFI (GPT)' } else { 'Legacy BIOS (MBR)' }))
        WLog ('Partitie EFI:       {0}' -f $(if ($efiPart)   { "#{0} {1}"  -f $efiPart.PartitionNumber,   (FmtHR $efiPart.Size)  } else { 'N/A' }))
        WLog ('Partitie MSR:       {0}' -f $(if ($msrPart)   { "#{0} {1}"  -f $msrPart.PartitionNumber,   (FmtHR $msrPart.Size)  } else { 'N/A' }))
        WLog ('Partitie OS:        #{0} {1}' -f $osPart.PartitionNumber, (FmtHR $osPart.Size))
        WLog ('Partitie Recovery:  {0}' -f $(if ($recovPart) { "#{0} {1}"  -f $recovPart.PartitionNumber, (FmtHR $recovPart.Size) } else { 'N/A' }))
        WLog ('Marime OS pe target (cu spatiu extra): {0} MB' -f $osSizeMB)
        $sync.TotalBytes = $osPart.Size  # used for progress bar

        # Progress: step 1 of 5
        $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.05))

        # ── Step 2: Partition target disk ─────────────────────────────────────
        WStep 'Creare tabel partitii pe discul destinatie (DESTRUCTIV)'

        if (-not $isDryRun) {
            # Log current state of destination disk before wiping
            WLog "Partitii existente pe Disk $dstDiskNumber INAINTE de stergere:"
            $existingParts = @(Get-Partition -DiskNumber $dstDiskNumber -ErrorAction SilentlyContinue)
            if ($existingParts.Count -gt 0) {
                foreach ($ep in $existingParts) {
                    WLog ("  Partitie #{0}: Tip={1}, Marime={2}" -f $ep.PartitionNumber, $ep.Type, (FmtHR $ep.Size))
                }
            } else {
                WLog "  (nicio partitie detectata pe discul destinatie)"
            }

            WLog 'Sterg disc destinatie (Clear-Disk)...'
            try {
                Clear-Disk -Number $dstDiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                WLog "Clear-Disk OK."
            } catch {
                # Escape { and } so the exception text (e.g. "Activity ID: {guid}") cannot
                # trigger a FormatException when PowerShell's error handling processes it.
                WLog ("Clear-Disk avertisment: " + ([string]$_ -replace '\{', '{{' -replace '\}', '}}')) 'WARN'
            }

            # Log partition state after Clear-Disk
            $remainParts = @(Get-Partition -DiskNumber $dstDiskNumber -ErrorAction SilentlyContinue)
            if ($remainParts.Count -gt 0) {
                WLog ("  Au ramas {0} partitii dupa Clear-Disk (vor fi sterse de diskpart clean)." -f $remainParts.Count) 'WARN'
            } else {
                WLog "  Discul destinatie este acum curat (fara partitii)." 'OK'
            }
        }

        # Build diskpart script
        $dpLines = @("select disk $dstDiskNumber", 'clean')
        if ($isUEFI) {
            $dpLines += 'convert gpt'
            $dpLines += "create partition efi size=$efiSizeMB"
            $dpLines += 'format quick fs=fat32 label="System"'
            $dpLines += "create partition msr size=$msrSizeMB"
        } else {
            $dpLines += 'convert mbr'
        }
        $dpLines += "create partition primary size=$osSizeMB"
        $dpLines += 'format quick fs=ntfs label="Windows"'
        if (-not $isUEFI) { $dpLines += 'active' }
        if ($recSizeMB -gt 0) {
            $dpLines += "create partition primary size=$recSizeMB"
            $dpLines += 'format quick fs=ntfs label="Recovery"'
            $dpLines += 'set id="de94bba4-06d1-4d40-a16a-bfd50179d6ac"'
            $dpLines += 'gpt attributes=0x8000000000000001'
        }
        $dpScript = $dpLines -join "`r`n"

        if ($isDryRun) {
            WLog "[DRY-RUN] Script diskpart care ar fi rulat:`n$dpScript" 'DRYRUN'
        } else {
            $dpFile = Join-Path $env:TEMP ('storemig-dp-{0}.txt' -f (Get-Date -Format 'HHmmss'))
            $dpScript | Out-File -FilePath $dpFile -Encoding ASCII
            WLog "Script diskpart (fisier: $dpFile):"
            foreach ($dpLine in $dpLines) { WLog "  $dpLine" }
            WLog "Rulez diskpart..."
            Invoke-Proc 'diskpart.exe' @('/s', $dpFile) | Out-Null
            Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
            WLog "Diskpart finalizat. Astept recunoasterea noilor partitii..."
            Start-Sleep -Seconds 3
            Update-Disk -Number $dstDiskNumber -ErrorAction SilentlyContinue
            $newParts = @(Get-Partition -DiskNumber $dstDiskNumber -ErrorAction SilentlyContinue)
            if ($newParts.Count -gt 0) {
                WLog ("Partitii noi create pe Disk {0}:" -f $dstDiskNumber) 'OK'
                foreach ($np in $newParts) {
                    WLog ("  Partitie #{0}: Tip={1}, Marime={2}" -f $np.PartitionNumber, $np.Type, (FmtHR $np.Size)) 'OK'
                }
            } else {
                WLog "Atentie: nu am detectat partitii pe discul destinatie dupa diskpart!" 'WARN'
            }
        }

        # Progress: step 2 of 5
        $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.12))

        # ── Step 3: Assign temp drive letters to target partitions ────────────
        WStep 'Atribuire litere temporare partitii destinatie'

        if (-not $isDryRun) {
            $dstParts = Get-Partition -DiskNumber $dstDiskNumber -ErrorAction Stop | Sort-Object PartitionNumber
            $dstEfi   = $dstParts | Where-Object { $_.Type -eq 'System'  } | Select-Object -First 1
            $dstOs    = $dstParts | Where-Object { $_.Type -eq 'Basic'   } | Select-Object -First 1

            WLog ("Partitii detectate pe discul destinatie: {0}" -f $dstParts.Count)
            foreach ($dp in $dstParts) {
                WLog ("  Partitie #{0}: Tip={1}, Marime={2}" -f $dp.PartitionNumber, $dp.Type, (FmtHR $dp.Size))
            }

            if ($isUEFI -and $dstEfi) {
                $tmpEfiLetter = Get-FreeLetter
                if ($tmpEfiLetter) {
                    WLog "Atribui litera $tmpEfiLetter`: partitiei EFI (#$($dstEfi.PartitionNumber))..."
                    Add-PartitionAccessPath -DiskNumber $dstDiskNumber `
                        -PartitionNumber $dstEfi.PartitionNumber `
                        -AccessPath "$tmpEfiLetter`:" -ErrorAction SilentlyContinue
                    WLog "EFI destinatie → $tmpEfiLetter`:" 'OK'
                } else {
                    WLog "Nu am gasit o litera libera pentru partitia EFI!" 'WARN'
                }
            } elseif ($isUEFI -and -not $dstEfi) {
                WLog "Atentie: nu am gasit partitia EFI (System) pe discul destinatie!" 'WARN'
            }
            if ($dstOs) {
                $tmpOsLetter = Get-FreeLetter
                if ($tmpOsLetter) {
                    WLog "Atribui litera $tmpOsLetter`: partitiei OS (#$($dstOs.PartitionNumber))..."
                    Add-PartitionAccessPath -DiskNumber $dstDiskNumber `
                        -PartitionNumber $dstOs.PartitionNumber `
                        -AccessPath "$tmpOsLetter`:" -ErrorAction SilentlyContinue
                    WLog "OS destinatie → $tmpOsLetter`:" 'OK'
                } else {
                    WLog "Nu am gasit o litera libera pentru partitia OS destinatie!" 'WARN'
                }
            } else {
                WLog "Atentie: nu am gasit partitia OS (Basic) pe discul destinatie!" 'WARN'
            }
        } else {
            $tmpOsLetter  = 'Z'
            $tmpEfiLetter = 'Y'
            WLog "[DRY-RUN] Ar atribui litere temporare Y: si Z: partitiilor destinatie." 'DRYRUN'
        }

        # Ensure source OS partition has a drive letter
        $srcOsLetter = $null
        try {
            $srcVol = Get-Volume -Partition $osPart -ErrorAction SilentlyContinue
            if ($srcVol -and $srcVol.DriveLetter) { $srcOsLetter = [string]$srcVol.DriveLetter }
        } catch {}
        if (-not $srcOsLetter -and -not $isDryRun) {
            $srcTmpLetter = Get-FreeLetter
            if ($srcTmpLetter) {
                Add-PartitionAccessPath -DiskNumber $srcDiskNumber `
                    -PartitionNumber $osPart.PartitionNumber `
                    -AccessPath "$srcTmpLetter`:" -ErrorAction SilentlyContinue
                $srcOsLetter = $srcTmpLetter
                WLog "OS sursa → $srcTmpLetter`: (litera temporara)"
            }
        }
        if (-not $srcOsLetter) {
            if ($isDryRun) { $srcOsLetter = 'C' } else { throw 'Nu am putut obtine litera pentru partitia OS sursa!' }
        }

        WLog "OS sursa: $srcOsLetter`:  |  OS destinatie: $tmpOsLetter`:"

        # Progress: step 3 of 5
        $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.15))

        # ── Step 4: Copy files with robocopy ──────────────────────────────────
        WStep "Copiere fisiere OS: $srcOsLetter`: → $tmpOsLetter`: (robocopy)"

        $roboLog  = Join-Path $env:TEMP ('robocopy-{0}.log' -f (Get-Date -Format 'HHmmss'))
        WLog "Log robocopy: $roboLog"

        # Robocopy /XD does not support wildcard paths like C:\Users\*\AppData\Local\Temp.
        # Enumerate actual per-user Temp directories at runtime and add each one individually.
        $userTempDirs = @(Get-ChildItem -Path "$srcOsLetter`:\Users" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } |
            Where-Object { Test-Path $_ })

        $roboArgs = @(
            "$srcOsLetter`:\", "$tmpOsLetter`:\",
            '/E',               # recurse including empty dirs
            '/B',               # backup mode  (bypass file ACL locks)
            '/COPYALL',         # copy all file attributes + ACLs
            '/DCOPY:DAT',       # copy dir data, ACLs, timestamps
            '/R:2', '/W:3',     # 2 retries, 3s wait
            # Exclude volatile / OS-specific files that can't be copied live
            '/XD',
                "$srcOsLetter`:\`$RECYCLE.BIN",
                "$srcOsLetter`:\System Volume Information",
                "$srcOsLetter`:\Windows\Temp"
        ) + $userTempDirs + @(
            '/XF',
                "$srcOsLetter`:\pagefile.sys",
                "$srcOsLetter`:\swapfile.sys",
                "$srcOsLetter`:\hiberfil.sys",
                "$srcOsLetter`:\DumpStack.log",
                "$srcOsLetter`:\DumpStack.log.tmp",
            # /TEE: output goes to both stdout (captured live by Invoke-Proc) and the log file.
            # /NFL /NDL /NP removed so file names, directory names and per-file progress are visible.
            '/TEE',
            "/LOG+:$roboLog"
        )

        if ($isDryRun) {
            WLog "[DRY-RUN] robocopy $($roboArgs -join ' ')" 'DRYRUN'
            $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.88))
        } else {
            $roboRC = Invoke-Proc 'robocopy.exe' $roboArgs -AllowNonZero
            # robocopy exit codes: 0-7 = success/warning, 8+ = error
            if ($roboRC -ge 8) {
                throw "robocopy a esuat cu cod $roboRC (>=8 inseamna eroare de copiere). Verifica $roboLog"
            }
            WLog "robocopy finalizat (cod $roboRC — $(if ($roboRC -lt 2) { 'OK, nicio modificare' } elseif ($roboRC -lt 4) { 'OK, fisiere copiate' } else { 'OK cu avertismente' }))" 'OK'
            $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.88))
        }

        # ── Step 5: Install bootloader ────────────────────────────────────────
        WStep 'Instalare bootloader Windows (bcdboot)'

        if ($isUEFI -and $tmpEfiLetter) {
            $bcdArgs = @("$tmpOsLetter`:\Windows", '/s', "$tmpEfiLetter`:", '/f', 'UEFI')
        } elseif ($isUEFI) {
            $bcdArgs = @("$tmpOsLetter`:\Windows", '/s', "$tmpOsLetter`:", '/f', 'UEFI')
        } else {
            $bcdArgs = @("$tmpOsLetter`:\Windows", '/s', "$tmpOsLetter`:", '/f', 'BIOS')
        }
        # Use explicit 64-bit path so bcdboot always runs as native 64-bit.
        # Sysnative exists only for 32-bit processes and bypasses WOW64 file-system
        # redirection to reach the real System32; fall back to System32 when already 64-bit.
        $bcdbootExe = if ([System.Environment]::Is64BitProcess) {
            "$env:SystemRoot\System32\bcdboot.exe"
        } elseif (Test-Path "$env:SystemRoot\Sysnative\bcdboot.exe") {
            "$env:SystemRoot\Sysnative\bcdboot.exe"
        } else {
            "$env:SystemRoot\System32\bcdboot.exe"
        }
        WLog "bcdboot.exe path: $bcdbootExe"
        Invoke-Proc $bcdbootExe $bcdArgs | Out-Null

        $sync.BytesDone = $sync.TotalBytes

        # ── Done ──────────────────────────────────────────────────────────────
        WStep 'Migrare OS finalizata cu succes'
        WLog '✔ Discul destinatie este acum bootabil cu Windows!' 'OK'
        WLog '' 'OK'
        WLog 'Pasi urmatori:' 'OK'
        WLog '  1. Opreste calculatorul: Start ▸ Shutdown' 'OK'
        WLog '  2. Inlocuieste fizic discul (scoate sursa, pune destinatia in loc)' 'OK'
        WLog '  3. Porneste calculatorul — Windows ar trebui sa booteze de pe noul disc' 'OK'
        WLog ('  Log complet: {0}' -f $logFile) 'OK'
        $sync.IsSuccess = $true

    } catch {
        $sync.LastError = $_.ToString()
        WLog "EROARE FATALA: $_" 'ERROR'
        $sync.IsSuccess = $false
    } finally {
        # Remove temp drive letters
        if ($srcTmpLetter -and -not $isDryRun) {
            try {
                Remove-PartitionAccessPath -DiskNumber $srcDiskNumber `
                    -PartitionNumber $osPart.PartitionNumber `
                    -AccessPath "$srcTmpLetter`:" -ErrorAction SilentlyContinue
            } catch {}
        }
        if ($tmpOsLetter -and -not $isDryRun) {
            try {
                $p = Get-Partition -DiskNumber $dstDiskNumber |
                     Where-Object { $_.DriveLetter -eq $tmpOsLetter[0] } |
                     Select-Object -First 1
                if ($p) {
                    Remove-PartitionAccessPath -DiskNumber $dstDiskNumber `
                        -PartitionNumber $p.PartitionNumber `
                        -AccessPath "$tmpOsLetter`:" -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        if ($tmpEfiLetter -and -not $isDryRun) {
            try {
                $p = Get-Partition -DiskNumber $dstDiskNumber |
                     Where-Object { $_.DriveLetter -eq $tmpEfiLetter[0] } |
                     Select-Object -First 1
                if ($p) {
                    Remove-PartitionAccessPath -DiskNumber $dstDiskNumber `
                        -PartitionNumber $p.PartitionNumber `
                        -AccessPath "$tmpEfiLetter`:" -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        $sync.IsRunning = $false
        $sync.IsDone    = $true
        WLog 'Worker migrare OS terminat.' 'INFO'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — GUI construction
# ─────────────────────────────────────────────────────────────────────────────

#region ── Main Form ──────────────────────────────────────────────────────────
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = "Windows Storage Migration Tool  v$Script:AppVersion"
# Taller window so all controls (incl. bottom buttons) are fully visible
$form.Size             = New-Object System.Drawing.Size(1500, 1000)
$form.MinimumSize      = New-Object System.Drawing.Size(1500, 1000)
$form.StartPosition    = 'CenterScreen'
$form.BackColor        = [System.Drawing.Color]::FromArgb(240, 242, 246)
# Base font +25%: 9 → 11  (applies to all controls that don't set their own font)
$form.Font             = New-Object System.Drawing.Font('Segoe UI', 11)
$form.FormBorderStyle  = 'Sizable'
#endregion

#region ── Header panel ───────────────────────────────────────────────────────
$pnlHeader            = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock       = 'Top'
$pnlHeader.Height     = 78  # slightly taller for larger fonts
$pnlHeader.BackColor  = [System.Drawing.Color]::FromArgb(0, 78, 152)

$lblTitle             = New-Object System.Windows.Forms.Label
# Emoji removed: floppy-disk was here
$lblTitle.Text        = "   Storage Migration Tool   —   v$Script:AppVersion"
$lblTitle.ForeColor   = [System.Drawing.Color]::White
# Font +25%: 13 → 16
$lblTitle.Font        = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.Dock        = 'Fill'
$lblTitle.TextAlign   = 'MiddleLeft'

$lblSubTitle          = New-Object System.Windows.Forms.Label
$lblSubTitle.Text     = "   Migrare OS Windows  |  Clonare disc sector-by-sector   —   $Script:AppDate"
$lblSubTitle.ForeColor= [System.Drawing.Color]::FromArgb(180, 210, 240)
# Font +25%: 8 → 10
$lblSubTitle.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
$lblSubTitle.Dock     = 'Bottom'
$lblSubTitle.Height   = 22
$lblSubTitle.TextAlign= 'MiddleLeft'

$pnlHeader.Controls.AddRange(@($lblTitle, $lblSubTitle))
$form.Controls.Add($pnlHeader)
#endregion

#region ── Mode selection ─────────────────────────────────────────────────────
$grpMode              = New-Object System.Windows.Forms.GroupBox
$grpMode.Text         = 'Mod Operare'
$grpMode.Location     = New-Object System.Drawing.Point(10, 86)
$grpMode.Size         = New-Object System.Drawing.Size(1454, 80)
$grpMode.Anchor       = 'Top,Left,Right'
# Font +25%: 9 Bold → 11 Bold
$grpMode.Font         = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)

$rbMigrate            = New-Object System.Windows.Forms.RadioButton
# Emoji removed: folder icon was here
$rbMigrate.Text       = 'Migrare OS  (partition + robocopy — muta Windows pe disc nou)'
$rbMigrate.Location   = New-Object System.Drawing.Point(16, 26)
$rbMigrate.Size       = New-Object System.Drawing.Size(703, 34)
# Font +25%: 9 → 11
$rbMigrate.Font       = New-Object System.Drawing.Font('Segoe UI', 11)
$rbMigrate.Checked    = $true

$rbClone              = New-Object System.Windows.Forms.RadioButton
# Emoji removed: disc icon was here
$rbClone.Text         = 'Clonare disc  (sector-by-sector, echivalent dd — orice tip de disc)'
$rbClone.Location     = New-Object System.Drawing.Point(729, 26)
$rbClone.Size         = New-Object System.Drawing.Size(703, 34)
# Font +25%: 9 → 11
$rbClone.Font         = New-Object System.Drawing.Font('Segoe UI', 11)

$grpMode.Controls.AddRange(@($rbMigrate, $rbClone))
$form.Controls.Add($grpMode)
#endregion

#region ── Disk selection ─────────────────────────────────────────────────────
$grpDisks             = New-Object System.Windows.Forms.GroupBox
$grpDisks.Text        = 'Selectare discuri'
$grpDisks.Location    = New-Object System.Drawing.Point(10, 174)
$grpDisks.Size        = New-Object System.Drawing.Size(1454, 84)
$grpDisks.Anchor      = 'Top,Left,Right'

# Source
$lblSrc               = New-Object System.Windows.Forms.Label
$lblSrc.Text          = 'Disc Sursa:'
$lblSrc.Location      = New-Object System.Drawing.Point(8, 28)
$lblSrc.Size          = New-Object System.Drawing.Size(94, 30)
$lblSrc.TextAlign     = 'MiddleRight'

$cmbSource            = New-Object System.Windows.Forms.ComboBox
$cmbSource.Location   = New-Object System.Drawing.Point(106, 25)
$cmbSource.Size       = New-Object System.Drawing.Size(380, 30)
$cmbSource.DropDownStyle = 'DropDownList'
# Font +25%: Consolas 8.5 → 10.5
$cmbSource.Font       = New-Object System.Drawing.Font('Consolas', 10.5)

# Target
$lblDst               = New-Object System.Windows.Forms.Label
$lblDst.Text          = 'Disc Tinta:'
$lblDst.Location      = New-Object System.Drawing.Point(498, 28)
$lblDst.Size          = New-Object System.Drawing.Size(88, 30)
$lblDst.TextAlign     = 'MiddleRight'

$cmbTarget            = New-Object System.Windows.Forms.ComboBox
$cmbTarget.Location   = New-Object System.Drawing.Point(590, 25)
$cmbTarget.Size       = New-Object System.Drawing.Size(322, 30)
$cmbTarget.DropDownStyle = 'DropDownList'
# Font +25%: Consolas 8.5 → 10.5
$cmbTarget.Font       = New-Object System.Drawing.Font('Consolas', 10.5)

# Refresh button — circle-arrow (U+27F3) replaced with text "Ref." to avoid rendering as []
$btnRefresh           = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = 'Refresh'
$btnRefresh.Location  = New-Object System.Drawing.Point(935, 23)
$btnRefresh.Size      = New-Object System.Drawing.Size(72, 36)
# Font +25%: 10 → 12.5
$btnRefresh.Font      = New-Object System.Drawing.Font('Segoe UI', 12.5)
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnRefresh.ForeColor = [System.Drawing.Color]::White
$btnRefresh.FlatAppearance.BorderSize = 0

$grpDisks.Controls.AddRange(@($lblSrc, $cmbSource, $lblDst, $cmbTarget, $btnRefresh))
# Responsive layout: recalculate disk-selector control widths/positions when group box resizes
$grpDisks.Add_SizeChanged({
    $cw = $grpDisks.ClientSize.Width
    if ($cw -lt 300) { return }
    $midX              = [int]($cw / 2)
    $cmbSource.Width   = $midX - $cmbSource.Left - 8
    $lblDst.Left       = $midX
    $cmbTarget.Left    = $midX + $lblDst.Width + 4
    $btnRefresh.Left   = $cw - $btnRefresh.Width - 8
    $cmbTarget.Width   = $btnRefresh.Left - $cmbTarget.Left - 8
})
$form.Controls.Add($grpDisks)
#endregion

#region ── Partition info grids ───────────────────────────────────────────────
$grpInfo              = New-Object System.Windows.Forms.GroupBox
$grpInfo.Text         = 'Partitii disc sursa (stanga)  vs  disc tinta (dreapta)'
$grpInfo.Location     = New-Object System.Drawing.Point(10, 266)
$grpInfo.Size         = New-Object System.Drawing.Size(1454, 196)
$grpInfo.Anchor       = 'Top,Left,Right'

function New-InfoGrid ([int]$x, [System.Drawing.Color]$headerColor) {
    $g                             = New-Object System.Windows.Forms.DataGridView
    $g.Location                    = New-Object System.Drawing.Point($x, 20)
    $g.Size                        = New-Object System.Drawing.Size(505, 168)
    $g.ReadOnly                    = $true
    $g.AllowUserToAddRows          = $false
    $g.AllowUserToDeleteRows       = $false
    $g.AllowUserToResizeRows       = $false
    $g.RowHeadersVisible           = $false
    $g.AutoSizeColumnsMode         = 'Fill'
    $g.BackgroundColor             = [System.Drawing.Color]::White
    $g.BorderStyle                 = 'None'
    # Log-area font kept at Consolas 8.5 per user request; grid cells are NOT part of the log
    # but they were separately at Consolas 8 — increase by 25%: 8 → 10
    $g.Font                        = New-Object System.Drawing.Font('Consolas', 10)
    $g.GridColor                   = [System.Drawing.Color]::FromArgb(220, 222, 228)
    $g.SelectionMode               = 'FullRowSelect'
    $g.ColumnHeadersDefaultCellStyle.BackColor = $headerColor
    $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    # Font +25%: 8.5 Bold → 10.5 Bold
    $g.ColumnHeadersDefaultCellStyle.Font      = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    $g.ColumnHeadersBorderStyle                = 'None'
    $g.DefaultCellStyle.SelectionBackColor     = [System.Drawing.Color]::FromArgb(205, 225, 250)
    $g.DefaultCellStyle.SelectionForeColor     = [System.Drawing.Color]::Black
    $g.EnableHeadersVisualStyles               = $false
    return $g
}

$dgvSrc = New-InfoGrid 2   ([System.Drawing.Color]::FromArgb(0, 112, 184))
# Destination header changed from green to red per user request
$dgvDst = New-InfoGrid 513 ([System.Drawing.Color]::FromArgb(192, 0, 0))

$grpInfo.Controls.AddRange(@($dgvSrc, $dgvDst))
# Responsive layout: keep both grids at equal half-width as group box resizes
$grpInfo.Add_SizeChanged({
    $cw = $grpInfo.ClientSize.Width
    if ($cw -lt 100) { return }
    $gw = [int](($cw - 12) / 2)   # 2px left margin + 8px gap + 2px right margin
    $dgvSrc.Width = $gw
    $dgvDst.Left  = $gw + 10
    $dgvDst.Width = $gw
})
$form.Controls.Add($grpInfo)
#endregion

#region ── Progress ───────────────────────────────────────────────────────────
$grpProgress          = New-Object System.Windows.Forms.GroupBox
$grpProgress.Text     = 'Progres transfer'
$grpProgress.Location = New-Object System.Drawing.Point(10, 470)
$grpProgress.Size     = New-Object System.Drawing.Size(1454, 148)
$grpProgress.Anchor   = 'Top,Left,Right'

$progressBar          = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(8, 26)
$progressBar.Size     = New-Object System.Drawing.Size(1434, 32)
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Style    = 'Continuous'
$progressBar.Anchor   = 'Top,Left,Right'

# Stat labels row — Y increased to accommodate taller progress bar
# Font +25%: 9 Bold → 11 Bold for lblPct; others inherit form font (11)
$lblPct               = New-Object System.Windows.Forms.Label
$lblPct.Text          = '0%'
$lblPct.Location      = New-Object System.Drawing.Point(8, 70)
$lblPct.Size          = New-Object System.Drawing.Size(64, 28)
$lblPct.Font          = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblPct.ForeColor     = [System.Drawing.Color]::FromArgb(0, 78, 152)
$lblPct.Anchor        = 'Top,Left'

$lblSpeed             = New-Object System.Windows.Forms.Label
$lblSpeed.Text        = 'Viteza: —'
$lblSpeed.Location    = New-Object System.Drawing.Point(80, 70)
$lblSpeed.Size        = New-Object System.Drawing.Size(180, 28)
$lblSpeed.ForeColor   = [System.Drawing.Color]::DimGray
$lblSpeed.Anchor      = 'Top,Left'

$lblDone              = New-Object System.Windows.Forms.Label
$lblDone.Text         = 'Copiat: —'
$lblDone.Location     = New-Object System.Drawing.Point(268, 70)
$lblDone.Size         = New-Object System.Drawing.Size(220, 28)
$lblDone.ForeColor    = [System.Drawing.Color]::DimGray
$lblDone.Anchor       = 'Top,Left'

$lblElapsed           = New-Object System.Windows.Forms.Label
# Stopwatch icon (U+23F1) removed — shows as [] without emoji font
$lblElapsed.Text      = 'Timp scurs:   --:--:--'
$lblElapsed.Location  = New-Object System.Drawing.Point(926, 70)
$lblElapsed.Size      = New-Object System.Drawing.Size(232, 28)
$lblElapsed.ForeColor = [System.Drawing.Color]::DimGray
$lblElapsed.Anchor    = 'Top,Right'

$lblEta               = New-Object System.Windows.Forms.Label
# Hourglass icon (U+23F3) removed — shows as [] without emoji font
$lblEta.Text          = 'Timp ramas:   --:--:--'
$lblEta.Location      = New-Object System.Drawing.Point(1166, 70)
$lblEta.Size          = New-Object System.Drawing.Size(232, 28)
$lblEta.ForeColor     = [System.Drawing.Color]::DimGray
$lblEta.Anchor        = 'Top,Right'

# Step name / status label
$lblStep              = New-Object System.Windows.Forms.Label
$lblStep.Text         = 'Pregatit. Selecteaza mod, sursa si destinatie, apoi apasa  Pornire.'
$lblStep.Location     = New-Object System.Drawing.Point(8, 108)
$lblStep.Size         = New-Object System.Drawing.Size(1434, 30)
$lblStep.ForeColor    = [System.Drawing.Color]::FromArgb(40, 80, 160)
# Font +25%: 8.5 Italic → 10.5 Italic
$lblStep.Font         = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Italic)
$lblStep.Anchor       = 'Top,Left,Right'

$grpProgress.Controls.AddRange(@($progressBar, $lblPct, $lblSpeed, $lblDone, $lblElapsed, $lblEta, $lblStep))
$form.Controls.Add($grpProgress)
#endregion

#region ── Log area ───────────────────────────────────────────────────────────
$grpLog               = New-Object System.Windows.Forms.GroupBox
$grpLog.Text          = 'Log operatiune'
$grpLog.Location      = New-Object System.Drawing.Point(10, 626)
$grpLog.Size          = New-Object System.Drawing.Size(1454, 240)
$grpLog.Anchor        = 'Top,Left,Right,Bottom'

$rtbLog               = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location      = New-Object System.Drawing.Point(5, 20)
$rtbLog.Size          = New-Object System.Drawing.Size(1442, 212)
$rtbLog.ReadOnly      = $true
$rtbLog.BackColor     = [System.Drawing.Color]::FromArgb(15, 15, 25)
$rtbLog.ForeColor     = [System.Drawing.Color]::FromArgb(200, 200, 210)
# Log font kept UNCHANGED per user request (Consolas 8.5)
$rtbLog.Font          = New-Object System.Drawing.Font('Consolas', 8.5)
$rtbLog.ScrollBars    = 'Vertical'
$rtbLog.WordWrap      = $false
$rtbLog.Anchor        = 'Top,Left,Right,Bottom'

$grpLog.Controls.Add($rtbLog)
$form.Controls.Add($grpLog)
#endregion

#region ── Button panel ───────────────────────────────────────────────────────
$pnlButtons           = New-Object System.Windows.Forms.Panel
$pnlButtons.Location  = New-Object System.Drawing.Point(10, 874)
$pnlButtons.Size      = New-Object System.Drawing.Size(1474, 56)
$pnlButtons.Anchor    = 'Bottom,Left,Right'

$chkDryRun            = New-Object System.Windows.Forms.CheckBox
# Emoji removed: magnifying-glass was here
$chkDryRun.Text       = 'Dry-Run  (simulare — nu se fac modificari pe disc)'
$chkDryRun.Location   = New-Object System.Drawing.Point(0, 15)
$chkDryRun.AutoSize   = $true
# Font +25%: 9 → 11
$chkDryRun.Font       = New-Object System.Drawing.Font('Segoe UI', 11)
$chkDryRun.Anchor     = 'Top,Left'

# ▶ (U+25B6) is in standard Segoe UI — safe to keep
# Start button: changed from blue to GREEN per user request
$btnStart             = New-Object System.Windows.Forms.Button
$btnStart.Text        = '▶  Pornire'
$btnStart.Location    = New-Object System.Drawing.Point(1000, 8)
$btnStart.Size        = New-Object System.Drawing.Size(152, 42)
# Font +25%: 10 Bold → 12.5 Bold
$btnStart.Font        = New-Object System.Drawing.Font('Segoe UI', 12.5, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor   = [System.Drawing.Color]::FromArgb(0, 153, 76)
$btnStart.ForeColor   = [System.Drawing.Color]::White
$btnStart.FlatStyle   = 'Flat'
$btnStart.FlatAppearance.BorderSize = 0
$btnStart.Cursor      = [System.Windows.Forms.Cursors]::Hand
$btnStart.Anchor      = 'Top,Right'

# ✕ (U+2715) is in standard Segoe UI — safe to keep
# Cancel button: stays RED
$btnCancel            = New-Object System.Windows.Forms.Button
$btnCancel.Text       = '✕  Anulare'
$btnCancel.Location   = New-Object System.Drawing.Point(1160, 8)
$btnCancel.Size       = New-Object System.Drawing.Size(152, 42)
# Font +25%: 10 Bold → 12.5 Bold
$btnCancel.Font       = New-Object System.Drawing.Font('Segoe UI', 12.5, [System.Drawing.FontStyle]::Bold)
$btnCancel.BackColor  = [System.Drawing.Color]::FromArgb(196, 43, 28)
$btnCancel.ForeColor  = [System.Drawing.Color]::White
$btnCancel.FlatStyle  = 'Flat'
$btnCancel.FlatAppearance.BorderSize = 0
$btnCancel.Enabled    = $false
$btnCancel.Cursor     = [System.Windows.Forms.Cursors]::Hand
$btnCancel.Anchor     = 'Top,Right'

# Exit button: BLUE — closes the application
$btnExit              = New-Object System.Windows.Forms.Button
$btnExit.Text         = 'Exit'
$btnExit.Location     = New-Object System.Drawing.Point(1320, 8)
$btnExit.Size         = New-Object System.Drawing.Size(152, 42)
$btnExit.Font         = New-Object System.Drawing.Font('Segoe UI', 12.5, [System.Drawing.FontStyle]::Bold)
$btnExit.BackColor    = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnExit.ForeColor    = [System.Drawing.Color]::White
$btnExit.FlatStyle    = 'Flat'
$btnExit.FlatAppearance.BorderSize = 0
$btnExit.Cursor       = [System.Windows.Forms.Cursors]::Hand
$btnExit.Anchor       = 'Top,Right'

$pnlButtons.Controls.AddRange(@($chkDryRun, $btnStart, $btnCancel, $btnExit))
$form.Controls.Add($pnlButtons)
#endregion

#region ── Status strip ───────────────────────────────────────────────────────
$statusStrip          = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor= [System.Drawing.Color]::FromArgb(220, 225, 235)
$statusLabel          = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text     = "Pregatit   |   Administrator: $env:USERNAME   |   Log: $Script:LogFile"
$statusLabel.Spring   = $true
$statusLabel.TextAlign= 'MiddleLeft'
$null = $statusStrip.Items.Add($statusLabel)
$form.Controls.Add($statusStrip)
#endregion

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 — GUI helper functions  (use form controls)
# ─────────────────────────────────────────────────────────────────────────────
$Script:AllDisks = @()

function Invoke-RefreshDisks {
    # Colectăm discurile și forțăm rezultatul să fie un Array, chiar dacă e 1 singur obiect
    # Folosim @(...) pentru a evita eroarea de StrictMode la .Count
    $rawDisks = @(Get-AllPhysicalDisks)
    $Script:AllDisks = $rawDisks

    $cmbSource.Items.Clear()
    $cmbTarget.Items.Clear()

    foreach ($d in $Script:AllDisks) {
        if ($null -ne $d -and $null -ne $d.Display) {
            [void]$cmbSource.Items.Add($d.Display)
            [void]$cmbTarget.Items.Add($d.Display)
        }
    }

    # Verificăm numărul de itemi folosind variabila de array forțată
    $diskCount = $Script:AllDisks.Length 
    # Notă: .Length funcționează mai bine pe Array-uri în mod Strict decât .Count

    if ($diskCount -ge 1) { 
        try { $cmbSource.SelectedIndex = 0 } catch {}
    }
    
    if ($diskCount -ge 2) { 
        try { $cmbTarget.SelectedIndex = 1 } catch {}
    } elseif ($diskCount -eq 1) {
        try { $cmbTarget.SelectedIndex = 0 } catch {}
    }

    Invoke-UpdateGrids
}

function Invoke-UpdateGrids {
    $srcDiskInfo = ''
    $dstDiskInfo = ''

    # Grila Sursă
    $dgvSrc.Rows.Clear(); $dgvSrc.Columns.Clear()
    # Folosim .Length in loc de .Count pentru siguranta in StrictMode
    if ($cmbSource.SelectedIndex -ge 0 -and $cmbSource.SelectedIndex -lt $Script:AllDisks.Length) {
        $sd   = $Script:AllDisks[$cmbSource.SelectedIndex]
        # Fortam $rows sa fie un array folosind @()
        $rows = @(Get-DiskPartitionTable $sd.Index)
        if ($rows.Length -gt 0) {
            foreach ($col in $rows[0].PSObject.Properties.Name) { [void]$dgvSrc.Columns.Add($col, $col) }
            foreach ($r in $rows) {
                [void]$dgvSrc.Rows.Add(($r.PSObject.Properties.Name | ForEach-Object { $r.$_ }))
            }
        }
        $srcDiskInfo = "Sursa: Disk $($sd.Index)  $($sd.Model)"
    }

    # Grila Destinație
    $dgvDst.Rows.Clear(); $dgvDst.Columns.Clear()
    if ($cmbTarget.SelectedIndex -ge 0 -and $cmbTarget.SelectedIndex -lt $Script:AllDisks.Length) {
        $td   = $Script:AllDisks[$cmbTarget.SelectedIndex]
        # Fortam $rows sa fie un array folosind @()
        $rows = @(Get-DiskPartitionTable $td.Index)
        if ($rows.Length -gt 0) {
            foreach ($col in $rows[0].PSObject.Properties.Name) { [void]$dgvDst.Columns.Add($col, $col) }
            foreach ($r in $rows) {
                [void]$dgvDst.Rows.Add(($r.PSObject.Properties.Name | ForEach-Object { $r.$_ }))
            }
        }
        $dstDiskInfo = "Tinta: Disk $($td.Index)  $($td.Model)"
    }

    # Update group title to show both source and destination disk info
    if ($srcDiskInfo -or $dstDiskInfo) {
        $grpInfo.Text = "Partitii  |  $srcDiskInfo   |   $dstDiskInfo"
    } else {
        $grpInfo.Text = 'Partitii disc sursa (stanga)  vs  disc tinta (dreapta)'
    }
}

function Write-GuiLog ([string]$line) {
    $color = if     ($line -match '\[ERROR\]')  { [System.Drawing.Color]::FromArgb(255, 90,  90)  }
             elseif ($line -match '\[WARN\]')   { [System.Drawing.Color]::FromArgb(255, 200, 50)  }
             elseif ($line -match '\[OK\]')     { [System.Drawing.Color]::FromArgb(80,  220, 100) }
             elseif ($line -match '\[DRYRUN\]') { [System.Drawing.Color]::FromArgb(150, 180, 255) }
             else                               { [System.Drawing.Color]::FromArgb(200, 200, 210) }
    $rtbLog.SelectionStart  = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor  = $color
    $rtbLog.AppendText($line + "`n")
    $rtbLog.ScrollToCaret()
}

function Reset-ProgressUI {
    $progressBar.Value  = 0
    $lblPct.Text        = '0%'
    $lblSpeed.Text      = 'Viteza: —'
    $lblDone.Text       = 'Copiat: —'
    $lblElapsed.Text    = 'Timp scurs:   --:--:--'
    $lblEta.Text        = 'Timp ramas:   --:--:--'
    $lblStep.Text       = 'Pornire...'
    $progressBar.ForeColor = [System.Drawing.SystemColors]::Highlight
}

function Set-UIRunning ([bool]$running) {
    $btnStart.Enabled   = -not $running
    $btnCancel.Enabled  = $running
    $btnRefresh.Enabled = -not $running
    $chkDryRun.Enabled  = -not $running
    $rbMigrate.Enabled  = -not $running
    $rbClone.Enabled    = -not $running
    $cmbSource.Enabled  = -not $running
    $cmbTarget.Enabled  = -not $running
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 — Timer: updates GUI from $sync (every 500 ms)
# ─────────────────────────────────────────────────────────────────────────────
$guiTimer          = New-Object System.Windows.Forms.Timer
$guiTimer.Interval = 500

$guiTimer.Add_Tick({
    try {
    # Suppress non-terminating errors locally so that $ErrorActionPreference = 'Stop'
    # (set at script scope) cannot trigger CheckActionPreference inside the timer tick.
    # CheckActionPreference internally calls String.Format on the error message, which
    # crashes when the message contains Activity ID GUIDs like {2ad3ad9f-...}.
    $local:ErrorActionPreference = 'Continue'

    # ── Drain log queue ──
    $line = [string]''
    while ($sync.LogQueue.TryDequeue([ref]$line)) {
        Write-GuiLog $line
    }

    # ── Update step label ──
    if ($sync.StepName) { $lblStep.Text = $sync.StepName }

    if ($sync.IsRunning) {
        $bytesDone  = $sync.BytesDone
        $totalBytes = $sync.TotalBytes
        $speedBps   = $sync.SpeedBps
        $elapsed    = [long]([DateTime]::UtcNow - $sync.StartTime).TotalSeconds

        # Progress bar + %
        if ($totalBytes -gt 0 -and $bytesDone -ge 0) {
            $pct = [math]::Min(100, [math]::Floor($bytesDone * 100 / $totalBytes))
            if ($pct -ne $progressBar.Value) { $progressBar.Value = $pct }
            $lblPct.Text  = "$pct%"
            $lblDone.Text = 'Copiat: {0} / {1}' -f (Format-HumanSize $bytesDone), (Format-HumanSize $totalBytes)
        }

        # Elapsed
        $lblElapsed.Text = 'Timp scurs:   ' + (Format-Hms $elapsed)

        # Speed + ETA
        if ($speedBps -gt 0) {
            $speedMB = [math]::Round($speedBps / 1MB, 1)
            $lblSpeed.Text = "Viteza: $speedMB MB/s"
            if ($totalBytes -gt 0 -and $bytesDone -gt 0 -and $bytesDone -lt $totalBytes) {
                $remaining   = $totalBytes - $bytesDone
                $etaSec      = [long]($remaining / $speedBps)
                $lblEta.Text = 'Timp ramas:   ' + (Format-Hms $etaSec)
            }
        } elseif ($sync.Phase -eq 'migrate') {
            # Migrate mode: no byte-level speed for robocopy — show elapsed only
            $lblSpeed.Text = 'Viteza: (robocopy)'
        }
    }

    # ── Operation completed ──
    if ($sync.IsDone) {
        $guiTimer.Stop()

        # Final log drain
        $line2 = [string]''
        while ($sync.LogQueue.TryDequeue([ref]$line2)) { Write-GuiLog $line2 }

        Set-UIRunning $false

        if ($sync.IsSuccess) {
            $progressBar.Value     = 100
            $progressBar.ForeColor = [System.Drawing.Color]::FromArgb(0, 180, 0)
            $lblPct.Text           = '100%'
            $lblStep.Text          = 'OK  Operatiune finalizata cu succes!'
            $lblStep.ForeColor     = [System.Drawing.Color]::FromArgb(0, 140, 0)
            $statusLabel.Text      = 'OK  Gata cu succes!'
            [System.Windows.Forms.MessageBox]::Show(
                "Operatiunea a fost finalizata cu succes!`n`nVerifica log-ul pentru detalii:`n$Script:LogFile",
                'Succes',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            $lblStep.Text      = "EROARE: $($sync.LastError)"
            $lblStep.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0)
            $statusLabel.Text  = 'EROARE!'
            [System.Windows.Forms.MessageBox]::Show(
                "Operatiunea a esuat.`n`nEroare:`n$($sync.LastError)`n`nVerifica log-ul:`n$Script:LogFile",
                'Eroare',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }

        # Cleanup runspace
        if ($Script:WorkerPS) {
            try { $Script:WorkerPS.Dispose() } catch {}
            $Script:WorkerPS = $null
        }
        if ($Script:WorkerRS) {
            try { $Script:WorkerRS.Close(); $Script:WorkerRS.Dispose() } catch {}
            $Script:WorkerRS = $null
        }
        $sync.IsDone    = $false
        $sync.IsRunning = $false
    }
    } catch {
        # Guard against any unhandled exception in the timer tick (e.g. a FormatException
        # triggered by PowerShell's CheckActionPreference when an error message contains
        # unescaped curly braces from external-tool output like DiskPart Activity IDs).
        # Escape braces in the caught exception text before displaying, to prevent a
        # recursive format failure in Write-GuiLog or subsequent error handling.
        $errText = ([string]$_) -replace '\{', '{{' -replace '\}', '}}'
        try { Write-GuiLog "[$((Get-Date).ToString('HH:mm:ss'))] [ERROR] Exceptie timer intern: $errText" } catch {}
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 10 — Event handlers
# ─────────────────────────────────────────────────────────────────────────────
$btnRefresh.Add_Click({
    $btnRefresh.Enabled = $false
    try     { Invoke-RefreshDisks }
    catch   { Write-GuiLog "[$((Get-Date).ToString('HH:mm:ss'))] [ERROR] Refresh discuri: $_" }
    finally { $btnRefresh.Enabled = $true }
})

$cmbSource.Add_SelectedIndexChanged({ Invoke-UpdateGrids })
$cmbTarget.Add_SelectedIndexChanged({ Invoke-UpdateGrids })

$btnCancel.Add_Click({
    $sync.IsCancelled  = $true
    $btnCancel.Enabled = $false
    Write-GuiLog "[$((Get-Date).ToString('HH:mm:ss'))] [WARN] Anulare solicitata de utilizator..."
    $lblStep.Text      = 'Anulare în curs...'
})

$btnExit.Add_Click({
    $form.Close()
})

$btnStart.Add_Click({
    # ── Validate selections ──
    if ($cmbSource.SelectedIndex -lt 0 -or $cmbTarget.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Selectează un disc sursă și un disc destinație.',
            'Selecție incompletă',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $srcDisk  = $Script:AllDisks[$cmbSource.SelectedIndex]
    $dstDisk  = $Script:AllDisks[$cmbTarget.SelectedIndex]
    $isClone  = $rbClone.Checked
    $isDryRun = $chkDryRun.Checked

    if ($srcDisk.Index -eq $dstDisk.Index) {
        [System.Windows.Forms.MessageBox]::Show(
            'Discul sursă și destinație sunt identice. Alege discuri diferite!',
            'Selecție invalidă',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    if (-not $isClone -and $dstDisk.SizeBytes -lt $srcDisk.SizeBytes) {
        [System.Windows.Forms.MessageBox]::Show(
            ("Discul destinație ({0}) este mai mic decât sursa ({1})!`n" +
             'Migrarea OS necesită ca destinația să fie cel puțin egală cu sursa.') -f
            $dstDisk.SizeHR, $srcDisk.SizeHR,
            'Disc prea mic',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $modeStr = if ($isClone) { 'CLONARE DISC  (sector-by-sector)' } else { 'MIGRARE OS  (robocopy + bcdboot)' }
    $warnStr = if ($isDryRun) { "[DRY-RUN]  Nicio modificare reala pe disc.`n`n" } else {
        "ATENTIE: TOATE DATELE DE PE DISCUL DESTINATIE VOR FI STERSE!`n`n"
    }
    $confirmMsg = @"
$warnStr
Mod:          $modeStr
Disc Sursă:   $($srcDisk.Display)
Disc Țintă:   $($dstDisk.Display)

Confirmi începerea operațiunii?
"@
    $r = [System.Windows.Forms.MessageBox]::Show(
        $confirmMsg, 'Confirmare operațiune',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    # ── Initialize shared state ──
    $sync.IsRunning   = $true
    $sync.IsCancelled = $false
    $sync.IsDone      = $false
    $sync.IsSuccess   = $false
    $sync.BytesDone   = 0L
    $sync.SpeedBps    = 0L
    $sync.LastError   = ''
    $sync.StepName    = 'Pornire...'
    $sync.TotalBytes  = if ($isClone) { $srcDisk.SizeBytes } else { 0L }
    $sync.Phase       = if ($isClone) { 'clone' } else { 'migrate' }

    Set-UIRunning $true
    Reset-ProgressUI
    $rtbLog.Clear()
    $lblStep.ForeColor = [System.Drawing.Color]::FromArgb(40, 80, 160)

    # Ensure log dir + file exist
    if (-not (Test-Path $Script:LogDir)) {
        $null = New-Item -ItemType Directory -Path $Script:LogDir -Force
    }
    Add-Content -Path $Script:LogFile -Value (
        '=== Storage Migration Tool v{0} — {1} ===' -f $Script:AppVersion, (Get-Date)) -Encoding UTF8

    $statusLabel.Text = "$(if ($isClone) {'Clonare'} else {'Migrare'}) în curs...   Log: $Script:LogFile"

    # ── Start background runspace ──
    $Script:WorkerRS = [RunspaceFactory]::CreateRunspace()
    $Script:WorkerRS.ApartmentState = 'STA'
    $Script:WorkerRS.ThreadOptions  = 'ReuseThread'
    $Script:WorkerRS.Open()

    $Script:WorkerPS = [PowerShell]::Create()
    $Script:WorkerPS.Runspace = $Script:WorkerRS

    if ($isClone) {
        [void]$Script:WorkerPS.AddScript($Script:CloneWorkerScript)
        [void]$Script:WorkerPS.AddArgument($sync)
        [void]$Script:WorkerPS.AddArgument($srcDisk.DeviceId)      # \\.\PHYSICALDRIVEn
        [void]$Script:WorkerPS.AddArgument($dstDisk.Index)
        [void]$Script:WorkerPS.AddArgument($dstDisk.DeviceId)
        [void]$Script:WorkerPS.AddArgument(4194304)                 # 4 MB chunk
        [void]$Script:WorkerPS.AddArgument($Script:LogFile)
    } else {
        [void]$Script:WorkerPS.AddScript($Script:MigrateWorkerScript)
        [void]$Script:WorkerPS.AddArgument($sync)
        [void]$Script:WorkerPS.AddArgument($srcDisk.Index)
        [void]$Script:WorkerPS.AddArgument($dstDisk.Index)
        [void]$Script:WorkerPS.AddArgument($isDryRun)
        [void]$Script:WorkerPS.AddArgument($Script:LogFile)
    }

    $Script:WorkerHandle = $Script:WorkerPS.BeginInvoke()
    $guiTimer.Start()
})

$form.Add_FormClosing({
    if ($sync.IsRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'O operațiune este în curs de desfășurare.`nForțezi închiderea (operațiunea va fi întreruptă)?',
            'Operațiune activă',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        $sync.IsCancelled = $true
        Start-Sleep -Milliseconds 700
    }
    $guiTimer.Stop()
    if ($Script:WorkerPS) { try { $Script:WorkerPS.Dispose() } catch {} }
    if ($Script:WorkerRS) { try { $Script:WorkerRS.Close(); $Script:WorkerRS.Dispose() } catch {} }
})

# Force initial responsive layout on first show (SizeChanged only fires on subsequent resizes)
$form.Add_Shown({
    # Trigger grpDisks layout helper
    $cw = $grpDisks.ClientSize.Width
    if ($cw -gt 300) {
        $midX = [int]($cw / 2)
        $cmbSource.Width = $midX - $cmbSource.Left - 8
        $lblDst.Left     = $midX
        $cmbTarget.Left  = $midX + $lblDst.Width + 4
        $btnRefresh.Left = $cw - $btnRefresh.Width - 8
        $cmbTarget.Width = $btnRefresh.Left - $cmbTarget.Left - 8
    }
    # Trigger grpInfo grid layout helper
    $cw2 = $grpInfo.ClientSize.Width
    if ($cw2 -gt 100) {
        $gw = [int](($cw2 - 12) / 2)
        $dgvSrc.Width = $gw
        $dgvDst.Left  = $gw + 10
        $dgvDst.Width = $gw
    }
})

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 11 — Entry point
# ─────────────────────────────────────────────────────────────────────────────
if (-not (Test-Path $Script:LogDir)) {
    $null = New-Item -ItemType Directory -Path $Script:LogDir -Force
}
Add-Content -Path $Script:LogFile `
    -Value "=== Storage Migration Tool v$Script:AppVersion started $(Get-Date) ===" `
    -Encoding UTF8

# Initial disk list
Invoke-RefreshDisks

# Welcome messages in log area
Write-GuiLog "  ╔══════════════════════════════════════════════════════════════════════╗"
Write-GuiLog "  ║   Windows Storage Migration Tool  v$Script:AppVersion  —  $Script:AppDate   ║"
Write-GuiLog "  ║   Repo: https://github.com/karen20ced4/NVME-Migrate                 ║"
Write-GuiLog "  ╚══════════════════════════════════════════════════════════════════════╝"
Write-GuiLog ''
Write-GuiLog "  Log fisier: $Script:LogFile"
Write-GuiLog "  Discuri detectate: $($Script:AllDisks.Count)"
foreach ($d in $Script:AllDisks) {
    Write-GuiLog "    Disk $($d.Index) ─ $($d.Display)"
}
Write-GuiLog ''
Write-GuiLog '  Mod 1 ▸ Migrare OS   : creaza partitii noi + robocopy + bcdboot (Windows pe disc nou)'
Write-GuiLog '  Mod 2 ▸ Clonare disc : copiere sector-by-sector (echivalent dd) — NTFS, exFAT, orice'
Write-GuiLog ''
Write-GuiLog '  Selecteaza modul, sursa si destinatia, apoi apasa  [▶ Pornire].'

# Launch GUI
[System.Windows.Forms.Application]::Run($form)
