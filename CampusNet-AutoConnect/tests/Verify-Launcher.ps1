[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('campusnet-launcher-' + [guid]::NewGuid().ToString('N'))
$passed = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Invoke-LauncherCase {
    param([string]$Directory, [int]$ExpectedExit, [string]$ExpectedOutput)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $start.Arguments = '/d /c ""' + (Join-Path $Directory 'QuickSetup.cmd') + '""'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $errors = $process.StandardError.ReadToEndAsync()
        $lines = New-Object 'Collections.Generic.List[string]'
        do {
            $read = $process.StandardOutput.ReadLineAsync()
            if (-not $read.Wait(15000)) { throw 'Launcher did not show its result in time.' }
            $line = $read.Result
            if ($null -eq $line) { throw 'Launcher closed without showing the pause prompt.' }
            $lines.Add($line)
        } until ($line -eq 'Press any key to close this window.')
        Assert (-not $process.WaitForExit(200)) 'Launcher closed before the user pressed a key.'
        $process.StandardInput.WriteLine()
        $process.StandardInput.Close()
        $remaining = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { throw 'Launcher did not close after input.' }
        $output = ($lines -join "`n") + $remaining.Result + $errors.Result
        Assert ($process.ExitCode -eq $ExpectedExit) 'Launcher lost the setup exit code.'
        Assert ($output.Contains($ExpectedOutput)) 'Launcher did not show the expected result.'
    }
    finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}

try {
    # Include spaces and shell metacharacters in the extracted folder name.
    $caseRoot = Join-Path $testRoot 'extracted (campus) & ! files'
    New-Item -ItemType Directory -Path (Join-Path $caseRoot 'src') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'QuickSetup.cmd') -Destination $caseRoot
    foreach ($name in @('CampusNet-AutoConnect.ps1', 'config.example.json', 'src\SrunCrypto.cs')) {
        Set-Content -LiteralPath (Join-Path $caseRoot $name) -Value 'Offline fixture only.'
    }
    $installer = Join-Path $caseRoot 'Install-CampusNet.ps1'
    Set-Content -LiteralPath $installer -Value "Write-Output 'Setup fixture completed.'; exit 0"
    Invoke-LauncherCase $caseRoot 0 'Setup fixture completed.'
    Set-Content -LiteralPath $installer -Value "throw 'Simulated startup failure.'"
    Invoke-LauncherCase $caseRoot 1 'Setup stopped with exit code 1.'
    Remove-Item -LiteralPath $installer
    Invoke-LauncherCase $caseRoot 1 'Extract the entire ZIP first'
    Write-Host "PASS: $passed launcher checks through cmd.exe. No real setup was run."
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
