### modificat de user
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
    Version : 1.0
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
$Script:AppVersion = '1.0'
$Script:AppDate    = '2026-03-21'
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
        Start-Process -FilePath 'powershell.exe' `
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
    $h = [math]::Floor($totalSeconds / 3600)
    $m = [math]::Floor(($totalSeconds % 3600) / 60)
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
    function Invoke-Proc ([string]$exe, [string[]]$args, [switch]$AllowNonZero) {
        $cmdStr = "$exe $($args -join ' ')"
        WLog "Rulez: $cmdStr"
        if ($isDryRun) { WLog "[DRY-RUN] Nu se executa: $cmdStr" 'DRYRUN'; return 0 }
        $psi                        = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $exe
        $psi.Arguments              = $args -join ' '
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        foreach ($l in ($out -split "`n")) { if ($l.Trim()) { WLog $l.Trim() } }
        foreach ($l in ($err -split "`n")) { if ($l.Trim()) { WLog $l.Trim() 'WARN' } }
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
        $efiSizeMB = if ($efiPart)   { [math]::Max(100, [math]::Floor($efiPart.Size   / 1MB)) } else { 100 }
        $msrSizeMB = if ($msrPart)   { [math]::Max(16,  [math]::Floor($msrPart.Size   / 1MB)) } else { 16  }
        $recSizeMB = if ($recovPart) { [math]::Max(500, [math]::Floor($recovPart.Size / 1MB)) } else { 0   }
        # Expand OS partition if destination is larger than source
        $extraMB   = [math]::Max(0, [math]::Floor(($dstDisk.Size - $srcDisk.Size) / 1MB))
        $osSizeMB  = [math]::Floor($osPart.Size / 1MB) + $extraMB

        WLog ('Stil boot:          {0}' -f (if ($isUEFI) { 'UEFI (GPT)' } else { 'Legacy BIOS (MBR)' }))
        WLog ('Partitie EFI:       {0}' -f (if ($efiPart)   { "#{0} {1}"  -f $efiPart.PartitionNumber,   (FmtHR $efiPart.Size)  } else { 'N/A' }))
        WLog ('Partitie MSR:       {0}' -f (if ($msrPart)   { "#{0} {1}"  -f $msrPart.PartitionNumber,   (FmtHR $msrPart.Size)  } else { 'N/A' }))
        WLog ('Partitie OS:        #{0} {1}' -f $osPart.PartitionNumber, (FmtHR $osPart.Size))
        WLog ('Partitie Recovery:  {0}' -f (if ($recovPart) { "#{0} {1}"  -f $recovPart.PartitionNumber, (FmtHR $recovPart.Size) } else { 'N/A' }))
        WLog ('Marime OS pe target (cu spatiu extra): {0} MB' -f $osSizeMB)
        $sync.TotalBytes = $osPart.Size  # used for progress bar

        # Progress: step 1 of 5
        $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.05))

        # ── Step 2: Partition target disk ─────────────────────────────────────
        WStep 'Creare tabel partitii pe discul destinatie (DESTRUCTIV)'

        if (-not $isDryRun) {
            WLog 'Sterg disc destinatie (Clear-Disk)...'
            try {
                Clear-Disk -Number $dstDiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
            } catch {
                WLog "Clear-Disk avertisment: $_" 'WARN'
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
            WLog "Diskpart script: $dpFile"
            Invoke-Proc 'diskpart.exe' @('/s', $dpFile) | Out-Null
            Remove-Item $dpFile -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Update-Disk -Number $dstDiskNumber -ErrorAction SilentlyContinue
        }

        # Progress: step 2 of 5
        $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.12))

        # ── Step 3: Assign temp drive letters to target partitions ────────────
        WStep 'Atribuire litere temporare partitii destinatie'

        if (-not $isDryRun) {
            $dstParts = Get-Partition -DiskNumber $dstDiskNumber -ErrorAction Stop | Sort-Object PartitionNumber
            $dstEfi   = $dstParts | Where-Object { $_.Type -eq 'System'  } | Select-Object -First 1
            $dstOs    = $dstParts | Where-Object { $_.Type -eq 'Basic'   } | Select-Object -First 1

            if ($isUEFI -and $dstEfi) {
                $tmpEfiLetter = Get-FreeLetter
                if ($tmpEfiLetter) {
                    Add-PartitionAccessPath -DiskNumber $dstDiskNumber `
                        -PartitionNumber $dstEfi.PartitionNumber `
                        -AccessPath "$tmpEfiLetter`:" -ErrorAction SilentlyContinue
                    WLog "EFI destinatie → $tmpEfiLetter`:"
                }
            }
            if ($dstOs) {
                $tmpOsLetter = Get-FreeLetter
                if ($tmpOsLetter) {
                    Add-PartitionAccessPath -DiskNumber $dstDiskNumber `
                        -PartitionNumber $dstOs.PartitionNumber `
                        -AccessPath "$tmpOsLetter`:" -ErrorAction SilentlyContinue
                    WLog "OS destinatie → $tmpOsLetter`:"
                }
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
        if (-not $srcOsLetter) { $srcOsLetter = if ($isDryRun) { 'C' } else { throw 'Nu am putut obtine litera pentru partitia OS sursa!' } }

        WLog "OS sursa: $srcOsLetter`:  |  OS destinatie: $tmpOsLetter`:"

        # Progress: step 3 of 5
        $sync.BytesDone = [long]([math]::Floor($sync.TotalBytes * 0.15))

        # ── Step 4: Copy files with robocopy ──────────────────────────────────
        WStep "Copiere fisiere OS: $srcOsLetter`: → $tmpOsLetter`: (robocopy)"

        $roboLog  = Join-Path $env:TEMP ('robocopy-{0}.log' -f (Get-Date -Format 'HHmmss'))
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
                "$srcOsLetter`:\Windows\Temp",
                "$srcOsLetter`:\Users\*\AppData\Local\Temp",
            '/XF',
                "$srcOsLetter`:\pagefile.sys",
                "$srcOsLetter`:\swapfile.sys",
                "$srcOsLetter`:\hiberfil.sys",
                "$srcOsLetter`:\DumpStack.log",
                "$srcOsLetter`:\DumpStack.log.tmp",
            '/NFL',             # no file names in log (faster)
            '/NDL',             # no directory names in log
            '/NP',              # no progress % (cleaner output)
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
        Invoke-Proc 'bcdboot.exe' $bcdArgs | Out-Null

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
$form.Size             = New-Object System.Drawing.Size(1020, 800)
$form.MinimumSize      = New-Object System.Drawing.Size(920, 730)
$form.StartPosition    = 'CenterScreen'
$form.BackColor        = [System.Drawing.Color]::FromArgb(240, 242, 246)
$form.Font             = New-Object System.Drawing.Font('Segoe UI', 9)
$form.FormBorderStyle  = 'Sizable'
#endregion

#region ── Header panel ───────────────────────────────────────────────────────
$pnlHeader            = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock       = 'Top'
$pnlHeader.Height     = 64
$pnlHeader.BackColor  = [System.Drawing.Color]::FromArgb(0, 78, 152)

$lblTitle             = New-Object System.Windows.Forms.Label
$lblTitle.Text        = "   💾  Windows Storage Migration Tool   —   v$Script:AppVersion"
$lblTitle.ForeColor   = [System.Drawing.Color]::White
$lblTitle.Font        = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.Dock        = 'Fill'
$lblTitle.TextAlign   = 'MiddleLeft'

$lblSubTitle          = New-Object System.Windows.Forms.Label
$lblSubTitle.Text     = "   Migrare OS Windows  |  Clonare disc sector-by-sector   —   $Script:AppDate"
$lblSubTitle.ForeColor= [System.Drawing.Color]::FromArgb(180, 210, 240)
$lblSubTitle.Font     = New-Object System.Drawing.Font('Segoe UI', 8)
$lblSubTitle.Dock     = 'Bottom'
$lblSubTitle.Height   = 20
$lblSubTitle.TextAlign= 'MiddleLeft'

$pnlHeader.Controls.AddRange(@($lblTitle, $lblSubTitle))
$form.Controls.Add($pnlHeader)
#endregion

#region ── Mode selection ─────────────────────────────────────────────────────
$grpMode              = New-Object System.Windows.Forms.GroupBox
$grpMode.Text         = 'Mod Operare'
$grpMode.Location     = New-Object System.Drawing.Point(10, 72)
$grpMode.Size         = New-Object System.Drawing.Size(994, 62)
$grpMode.Font         = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

$rbMigrate            = New-Object System.Windows.Forms.RadioButton
$rbMigrate.Text       = '📁  Migrare OS  (partition + robocopy + bcdboot — muta Windows pe disc nou)'
$rbMigrate.Location   = New-Object System.Drawing.Point(16, 22)
$rbMigrate.Size       = New-Object System.Drawing.Size(490, 26)
$rbMigrate.Font       = New-Object System.Drawing.Font('Segoe UI', 9)
$rbMigrate.Checked    = $true

$rbClone              = New-Object System.Windows.Forms.RadioButton
$rbClone.Text         = '💿  Clonare disc  (sector-by-sector, echivalent dd — orice tip de disc)'
$rbClone.Location     = New-Object System.Drawing.Point(516, 22)
$rbClone.Size         = New-Object System.Drawing.Size(470, 26)
$rbClone.Font         = New-Object System.Drawing.Font('Segoe UI', 9)

$grpMode.Controls.AddRange(@($rbMigrate, $rbClone))
$form.Controls.Add($grpMode)
#endregion

#region ── Disk selection ─────────────────────────────────────────────────────
$grpDisks             = New-Object System.Windows.Forms.GroupBox
$grpDisks.Text        = 'Selectare discuri'
$grpDisks.Location    = New-Object System.Drawing.Point(10, 140)
$grpDisks.Size        = New-Object System.Drawing.Size(994, 68)

# Source
$lblSrc               = New-Object System.Windows.Forms.Label
$lblSrc.Text          = 'Disc Sursă:'
$lblSrc.Location      = New-Object System.Drawing.Point(8, 26)
$lblSrc.Size          = New-Object System.Drawing.Size(84, 23)
$lblSrc.TextAlign     = 'MiddleRight'

$cmbSource            = New-Object System.Windows.Forms.ComboBox
$cmbSource.Location   = New-Object System.Drawing.Point(96, 23)
$cmbSource.Size       = New-Object System.Drawing.Size(396, 23)
$cmbSource.DropDownStyle = 'DropDownList'
$cmbSource.Font       = New-Object System.Drawing.Font('Consolas', 8.5)

# Target
$lblDst               = New-Object System.Windows.Forms.Label
$lblDst.Text          = 'Disc Țintă:'
$lblDst.Location      = New-Object System.Drawing.Point(502, 26)
$lblDst.Size          = New-Object System.Drawing.Size(84, 23)
$lblDst.TextAlign     = 'MiddleRight'

$cmbTarget            = New-Object System.Windows.Forms.ComboBox
$cmbTarget.Location   = New-Object System.Drawing.Point(590, 23)
$cmbTarget.Size       = New-Object System.Drawing.Size(336, 23)
$cmbTarget.DropDownStyle = 'DropDownList'
$cmbTarget.Font       = New-Object System.Drawing.Font('Consolas', 8.5)

$btnRefresh           = New-Object System.Windows.Forms.Button
$btnRefresh.Text      = '⟳'
$btnRefresh.Location  = New-Object System.Drawing.Point(932, 21)
$btnRefresh.Size      = New-Object System.Drawing.Size(52, 27)
$btnRefresh.Font      = New-Object System.Drawing.Font('Segoe UI', 10)
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnRefresh.ForeColor = [System.Drawing.Color]::White
$btnRefresh.FlatAppearance.BorderSize = 0

$grpDisks.Controls.AddRange(@($lblSrc, $cmbSource, $lblDst, $cmbTarget, $btnRefresh))
$form.Controls.Add($grpDisks)
#endregion

#region ── Partition info grids ───────────────────────────────────────────────
$grpInfo              = New-Object System.Windows.Forms.GroupBox
$grpInfo.Text         = 'Partiții disc sursă (stânga)  vs  disc țintă (dreapta)'
$grpInfo.Location     = New-Object System.Drawing.Point(10, 214)
$grpInfo.Size         = New-Object System.Drawing.Size(994, 168)

function New-InfoGrid ([int]$x, [System.Drawing.Color]$headerColor) {
    $g                             = New-Object System.Windows.Forms.DataGridView
    $g.Location                    = New-Object System.Drawing.Point($x, 18)
    $g.Size                        = New-Object System.Drawing.Size(490, 143)
    $g.ReadOnly                    = $true
    $g.AllowUserToAddRows          = $false
    $g.AllowUserToDeleteRows       = $false
    $g.AllowUserToResizeRows       = $false
    $g.RowHeadersVisible           = $false
    $g.AutoSizeColumnsMode         = 'Fill'
    $g.BackgroundColor             = [System.Drawing.Color]::White
    $g.BorderStyle                 = 'None'
    $g.Font                        = New-Object System.Drawing.Font('Consolas', 8)
    $g.GridColor                   = [System.Drawing.Color]::FromArgb(220, 222, 228)
    $g.SelectionMode               = 'FullRowSelect'
    $g.ColumnHeadersDefaultCellStyle.BackColor = $headerColor
    $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $g.ColumnHeadersDefaultCellStyle.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
    $g.ColumnHeadersBorderStyle                = 'None'
    $g.DefaultCellStyle.SelectionBackColor     = [System.Drawing.Color]::FromArgb(205, 225, 250)
    $g.DefaultCellStyle.SelectionForeColor     = [System.Drawing.Color]::Black
    $g.EnableHeadersVisualStyles               = $false
    return $g
}

$dgvSrc = New-InfoGrid 2   ([System.Drawing.Color]::FromArgb(0, 112, 184))
$dgvDst = New-InfoGrid 499 ([System.Drawing.Color]::FromArgb(40, 140, 60))

$grpInfo.Controls.AddRange(@($dgvSrc, $dgvDst))
$form.Controls.Add($grpInfo)
#endregion

#region ── Progress ───────────────────────────────────────────────────────────
$grpProgress          = New-Object System.Windows.Forms.GroupBox
$grpProgress.Text     = 'Progres transfer'
$grpProgress.Location = New-Object System.Drawing.Point(10, 388)
$grpProgress.Size     = New-Object System.Drawing.Size(994, 120)

$progressBar          = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(8, 22)
$progressBar.Size     = New-Object System.Drawing.Size(976, 28)
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Style    = 'Continuous'

# Stat labels row
$lblPct               = New-Object System.Windows.Forms.Label
$lblPct.Text          = '0%'
$lblPct.Location      = New-Object System.Drawing.Point(8, 58)
$lblPct.Size          = New-Object System.Drawing.Size(56, 20)
$lblPct.Font          = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblPct.ForeColor     = [System.Drawing.Color]::FromArgb(0, 78, 152)

$lblSpeed             = New-Object System.Windows.Forms.Label
$lblSpeed.Text        = 'Viteză: —'
$lblSpeed.Location    = New-Object System.Drawing.Point(72, 58)
$lblSpeed.Size        = New-Object System.Drawing.Size(150, 20)
$lblSpeed.ForeColor   = [System.Drawing.Color]::DimGray

$lblDone              = New-Object System.Windows.Forms.Label
$lblDone.Text         = 'Copiat: —'
$lblDone.Location     = New-Object System.Drawing.Point(230, 58)
$lblDone.Size         = New-Object System.Drawing.Size(200, 20)
$lblDone.ForeColor    = [System.Drawing.Color]::DimGray

$lblElapsed           = New-Object System.Windows.Forms.Label
$lblElapsed.Text      = '⏱  Timp scurs:   --:--:--'
$lblElapsed.Location  = New-Object System.Drawing.Point(440, 58)
$lblElapsed.Size      = New-Object System.Drawing.Size(210, 20)
$lblElapsed.ForeColor = [System.Drawing.Color]::DimGray

$lblEta               = New-Object System.Windows.Forms.Label
$lblEta.Text          = '⏳  Timp rămas:   --:--:--'
$lblEta.Location      = New-Object System.Drawing.Point(660, 58)
$lblEta.Size          = New-Object System.Drawing.Size(210, 20)
$lblEta.ForeColor     = [System.Drawing.Color]::DimGray

# Step name / status label
$lblStep              = New-Object System.Windows.Forms.Label
$lblStep.Text         = 'Pregătit. Selectează mod, sursă și destinație, apoi apasă  ▶ Pornire.'
$lblStep.Location     = New-Object System.Drawing.Point(8, 84)
$lblStep.Size         = New-Object System.Drawing.Size(976, 24)
$lblStep.ForeColor    = [System.Drawing.Color]::FromArgb(40, 80, 160)
$lblStep.Font         = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Italic)

$grpProgress.Controls.AddRange(@($progressBar, $lblPct, $lblSpeed, $lblDone, $lblElapsed, $lblEta, $lblStep))
$form.Controls.Add($grpProgress)
#endregion

#region ── Log area ───────────────────────────────────────────────────────────
$grpLog               = New-Object System.Windows.Forms.GroupBox
$grpLog.Text          = 'Log operațiune'
$grpLog.Location      = New-Object System.Drawing.Point(10, 514)
$grpLog.Size          = New-Object System.Drawing.Size(994, 210)
$grpLog.Anchor        = 'Top,Left,Right,Bottom'

$rtbLog               = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location      = New-Object System.Drawing.Point(5, 18)
$rtbLog.Size          = New-Object System.Drawing.Size(982, 185)
$rtbLog.ReadOnly      = $true
$rtbLog.BackColor     = [System.Drawing.Color]::FromArgb(15, 15, 25)
$rtbLog.ForeColor     = [System.Drawing.Color]::FromArgb(200, 200, 210)
$rtbLog.Font          = New-Object System.Drawing.Font('Consolas', 8.5)
$rtbLog.ScrollBars    = 'Vertical'
$rtbLog.WordWrap      = $false
$rtbLog.Anchor        = 'Top,Left,Right,Bottom'

$grpLog.Controls.Add($rtbLog)
$form.Controls.Add($grpLog)
#endregion

#region ── Button panel ───────────────────────────────────────────────────────
$pnlButtons           = New-Object System.Windows.Forms.Panel
$pnlButtons.Location  = New-Object System.Drawing.Point(10, 730)
$pnlButtons.Size      = New-Object System.Drawing.Size(994, 48)
$pnlButtons.Anchor    = 'Bottom,Left,Right'

$chkDryRun            = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text       = '🔍  Dry-Run  (simulare — nu se fac modificari pe disc)'
$chkDryRun.Location   = New-Object System.Drawing.Point(0, 14)
$chkDryRun.AutoSize   = $true
$chkDryRun.Font       = New-Object System.Drawing.Font('Segoe UI', 9)

$btnStart             = New-Object System.Windows.Forms.Button
$btnStart.Text        = '▶  Pornire'
$btnStart.Location    = New-Object System.Drawing.Point(704, 7)
$btnStart.Size        = New-Object System.Drawing.Size(136, 36)
$btnStart.Font        = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor   = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnStart.ForeColor   = [System.Drawing.Color]::White
$btnStart.FlatStyle   = 'Flat'
$btnStart.FlatAppearance.BorderSize = 0
$btnStart.Cursor      = [System.Windows.Forms.Cursors]::Hand

$btnCancel            = New-Object System.Windows.Forms.Button
$btnCancel.Text       = '✕  Anulare'
$btnCancel.Location   = New-Object System.Drawing.Point(848, 7)
$btnCancel.Size       = New-Object System.Drawing.Size(136, 36)
$btnCancel.Font       = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnCancel.BackColor  = [System.Drawing.Color]::FromArgb(196, 43, 28)
$btnCancel.ForeColor  = [System.Drawing.Color]::White
$btnCancel.FlatStyle  = 'Flat'
$btnCancel.FlatAppearance.BorderSize = 0
$btnCancel.Enabled    = $false
$btnCancel.Cursor     = [System.Windows.Forms.Cursors]::Hand

$pnlButtons.Controls.AddRange(@($chkDryRun, $btnStart, $btnCancel))
$form.Controls.Add($pnlButtons)
#endregion

#region ── Status strip ───────────────────────────────────────────────────────
$statusStrip          = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor= [System.Drawing.Color]::FromArgb(220, 225, 235)
$statusLabel          = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text     = "Pregătit   |   Administrator: $env:USERNAME   |   Log: $Script:LogFile"
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
        $grpInfo.Text = "Partiții:  Disk $($sd.Index) — $($sd.Model)  (stânga = sursă, dreapta = țintă)"
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
    $lblSpeed.Text      = 'Viteză: —'
    $lblDone.Text       = 'Copiat: —'
    $lblElapsed.Text    = '⏱  Timp scurs:   --:--:--'
    $lblEta.Text        = '⏳  Timp rămas:   --:--:--'
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
        $lblElapsed.Text = '⏱  Timp scurs:   ' + (Format-Hms $elapsed)

        # Speed + ETA
        if ($speedBps -gt 0) {
            $speedMB = [math]::Round($speedBps / 1MB, 1)
            $lblSpeed.Text = "Viteză: $speedMB MB/s"
            if ($totalBytes -gt 0 -and $bytesDone -gt 0 -and $bytesDone -lt $totalBytes) {
                $remaining   = $totalBytes - $bytesDone
                $etaSec      = [long]($remaining / $speedBps)
                $lblEta.Text = '⏳  Timp rămas:   ' + (Format-Hms $etaSec)
            }
        } elseif ($sync.Phase -eq 'migrate') {
            # Migrate mode: no byte-level speed for robocopy — show elapsed only
            $lblSpeed.Text = 'Viteză: (robocopy)'
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
            $lblStep.Text          = '✔  Operațiune finalizată cu succes!'
            $lblStep.ForeColor     = [System.Drawing.Color]::FromArgb(0, 140, 0)
            $statusLabel.Text      = '✔  Gata cu succes!'
            [System.Windows.Forms.MessageBox]::Show(
                "Operațiunea a fost finalizată cu succes!`n`nVerifică log-ul pentru detalii:`n$Script:LogFile",
                '✔  Succes',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            $lblStep.Text      = "✖  Eroare: $($sync.LastError)"
            $lblStep.ForeColor = [System.Drawing.Color]::FromArgb(180, 0, 0)
            $statusLabel.Text  = '✖  Eroare!'
            [System.Windows.Forms.MessageBox]::Show(
                "Operațiunea a eșuat.`n`nEroare:`n$($sync.LastError)`n`nVerifică log-ul:`n$Script:LogFile",
                '✖  Eroare',
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
        "⚠  ATENTIE: TOATE DATELE DE PE DISCUL DESTINATIE VOR FI STERSE!`n`n"
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
