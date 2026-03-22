Diagnostic summary

Problem observed: the GUI crashes during the timer tick with the exception “Error formatting a string: Format specifier was invalid.” The stack trace shows the exception originates while the WinForms Timer handler is running (the GUI update loop). The script’s own log shows DiskPart and robocopy output just before the crash.

Two lines from your uploaded script (verbatim):

    “Two operation modes, both with a Windows Forms graphical interface:”  
    “► Migrare OS   – Migrates a Windows installation to a new disk.”

Why this error happens (concise, concrete)

    PowerShell format operator (-f) is being used somewhere on a string that contains braces or an invalid format token. When PowerShell tries to format a string that contains { or } sequences (or an invalid :{format} specifier), it throws “Format specifier was invalid.”

    In your script the GUI timer drains a log queue and writes each line into the RichTextBox. The worker runspace enqueues many lines coming directly from external tools (DiskPart, robocopy, bcdboot). If any of those lines contain braces { or a stray format-like token, and later code attempts to treat that line with -f (or PowerShell tries to format an exception message that contains braces), the format operator fails and the Timer tick throws — which matches the stack trace. The crash happens inside the Timer tick because that code is the consumer of the log lines.

Most likely root causes in your script (ordered)

    Unescaped external output (DiskPart / robocopy / bcdboot) contains { or } and later a -f is applied to a string that includes that text (directly or indirectly).

    An exception is thrown inside the Timer tick while PowerShell is trying to format the exception message (PowerShell sometimes formats exception messages using -f internally), and that formatting fails because the exception message contains braces. The stack trace shows ExceptionHandlingOps.CheckActionPreference which is consistent with an exception during error handling/formatting.

    Less likely but possible: a -f call in your code receives the wrong number/type of arguments (e.g., '{0} {1}' -f $singleValue) — search for nested -f usages to confirm.

Concrete fixes (apply in this order)
1) Sanitize/escape external stdout/stderr before enqueuing

Edit Invoke-Proc where you read $out / $err and escape braces before calling WLog:
powershell

# inside Invoke-Proc, replace the foreach that logs stdout/stderr with:
foreach ($l in ($out -split "`n")) {
    $t = $l.Trim()
    if ($t) {
        # Escape braces so later formatting won't fail
        $t = $t -replace '\{','{{' -replace '\}','}}'
        WLog $t
    }
}
foreach ($l in ($err -split "`n")) {
    $t = $l.Trim()
    if ($t) {
        $t = $t -replace '\{','{{' -replace '\}','}}'
        WLog $t 'WARN'
    }
}

This prevents any { or } coming from external tools from being interpreted as format placeholders later.
2) Make WLog / Write-GuiLog defensive (treat messages as literal)

Ensure WLog and Write-GuiLog never call -f on user/external strings. In Write-GuiLog you already append the line directly; add a guard to coerce to string and replace nulls:
powershell

function Write-GuiLog ([string]$line) {
    if (-not $line) { $line = '' }
    $line = [string]$line
    # optional: collapse CRLF to single LF
    $line = $line -replace "`r`n","`n"
    # existing color selection + append
    ...
}

3) Wrap the GUI timer Tick handler in try/catch and log exceptions safely

This prevents the whole GUI from crashing and gives a clear error message:
powershell

$guiTimer.Add_Tick({
    try {
        # existing Tick body ...
    } catch {
        # Escape braces in exception text before logging
        $errText = ($_.ToString()) -replace '\{','{{' -replace '\}','}}'
        Write-GuiLog "[$((Get-Date).ToString('HH:mm:ss'))] [ERROR] Timer tick exception: $errText"
    }
})

4) Audit all -f usages that format strings built from external data

Search for lines like '{0} ...' -f $someVar where $someVar may contain braces. Replace with concatenation or ensure the formatted arguments are primitive values (numbers/strings) and not raw external text.

Example safer alternative:
powershell

# instead of:
WLog ('Partitie EFI: {0}' -f $someStringFromTool)

# use:
WLog ("Partitie EFI: " + $someStringFromTool)

Quick test plan (how to verify the fix)

    Apply the three code changes above (escape external output, defensive Write-GuiLog, try/catch in timer).

    Run the script in Dry-Run mode (check the checkbox) so no destructive disk operations occur.

    Start a migration that triggers DiskPart/robocopy output (your earlier run did this). Confirm the GUI no longer throws and the log area continues to update.

    If Dry-Run succeeds, run a real migration on a non-critical target or a small test VM/disk.

Extra notes about your environment

    Your target disk is connected via a USB bridge (Realtek RTL9210B). That usually works but can cause quirks with Set-Disk -IsOffline or exclusive raw access; keep that in mind if you later see I/O errors. The console log you posted shows DiskPart and partition creation succeeded before the crash, so the hardware path is probably OK for partitioning.
