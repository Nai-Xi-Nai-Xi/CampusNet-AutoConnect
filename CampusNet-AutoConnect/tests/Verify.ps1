[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('campusnet-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}

function Read-ScriptAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) ("PowerShell parse failed: $Path")
    return $ast
}

function Get-FunctionSource {
    param($Ast)
    $source = (($Ast.EndBlock.Statements |
        Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } |
        ForEach-Object { $_.Extent.Text }) -join "`r`n")
    return $source.Replace('$PSScriptRoot', '$script:runtimeRoot')
}

try {
    $runtimeAst = Read-ScriptAst (Join-Path $root 'CampusNet-AutoConnect.ps1')
    $setupAst = Read-ScriptAst (Join-Path $root 'Install-CampusNet.ps1')
    $null = Read-ScriptAst (Join-Path $root 'Uninstall-CampusNet.ps1')
    $template = Get-Content -Raw (Join-Path $root 'config.example.json') | ConvertFrom-Json
    Assert ([bool]$template.Campus.PSObject.Properties['CreateOpenProfile']) 'Missing public Wi-Fi setting.'
    Assert ($template.Runtime.AuthWaitSeconds -gt 0) 'Missing auth confirmation timeout.'
    Assert (-not $template.Vpn.PSObject.Properties['StartWhenCampusUnavailable']) 'Unsafe VPN fallback setting remains.'

    . ([scriptblock]::Create((Get-FunctionSource $runtimeAst)))
    $script:runtimeRoot = $root
    $Config = $template
    $Config.Runtime.AuthWaitSeconds = 1
    $Once = $false
    $PauseAtEnd = $false
    function Write-Log { param([string]$Message) }
    function Start-Sleep { param([int]$Seconds) }
    function Get-LocalIpv4 { param([string]$InterfaceAlias) return '192.0.2.10' }
    function Get-Password { return 'test-password' }

    $Config.Campus.Username = 'student'
    $Config.Campus.PortalBase = 'http://192.0.2.1'
    $Config.Campus.AcId = '3'
    $script:requests = New-Object 'Collections.Generic.List[string]'
    $script:loggedIn = $false
    function Invoke-DirectGet {
        param([string]$Url)
        $script:requests.Add($Url)
        if ($Url -match '/rad_user_info\?callback=') {
            if ($script:loggedIn) {
                return 'campusnet_status({"error":"ok","user_name":"student","online_ip":"192.0.2.10"})'
            }
            return 'campusnet_status({"error":"not_online_error","client_ip":"192.0.2.10","srun_ver":"SRun"})'
        }
        if ($Url -match '/get_challenge\?') {
            return 'callback({"res":"ok","challenge":"12345678901234567890123456789012","client_ip":"192.0.2.10"})'
        }
        if ($Url -match '/srun_portal\?') {
            $script:loggedIn = $true
            return 'callback({"error":"ok","suc_msg":"login_ok"})'
        }
        throw 'Unexpected authentication request.'
    }
    Assert (Invoke-SrunLogin $Config.Campus) 'SRun challenge/login/online confirmation failed.'
    Assert ([CampusNetSrunCrypto]::SrunInfo('hello', '1234567890123456') -ceq '{SRBX1}4+YAczE1Rmf/mJd8') 'SRun encryption vector failed.'
    $unicodePassword = [string][char]0x5bc6 + [string][char]0x7801
    Assert ([CampusNetSrunCrypto]::SrunInfo($unicodePassword, '1234567890123456') -ceq '{SRBX1}bCybnMw7H+XgUlEB') 'SRun UTF-8 encryption vector failed.'
    Assert ($script:requests.Count -eq 4) 'SRun did not query status before and after login.'
    Assert (($script:requests[2] -match 'ac_id=3') -and ($script:requests[2] -notmatch 'test-password')) 'SRun request encoding failed.'
    $script:requests.Clear()
    function Get-Password { throw 'An already-online session must not read the password.' }
    Assert (Invoke-SrunLogin $Config.Campus) 'SRun did not reuse an authenticated session.'
    Assert ($script:requests.Count -eq 1) 'Already-online SRun sent a new login.'
    Assert (-not (Test-SrunOnline ([pscustomobject]@{error='ok'}) 'student')) 'Generic error=ok incorrectly confirmed authentication.'
    Assert (-not (Test-SrunOnline ([pscustomobject]@{error='ok';user_name='other'}) 'student')) 'Another user was accepted.'
    Assert ((ConvertFrom-Jsonp 'cb({"error":"ok"});').error -eq 'ok') 'JSONP parsing failed.'

    $Config.Campus.Drcom.ApiBase = 'http://192.0.2.1:801'
    $script:requests.Clear()
    $script:loggedIn = $false
    function Get-Password { return 'test-password' }
    function Invoke-DirectGet {
        param([string]$Url)
        $script:requests.Add($Url)
        if ($Url -match '/drcom/chkstatus\?') {
            return 'cb({"result":0,"v46ip":"192.0.2.10"})'
        }
        if ($Url -match '/online_list\?') {
            if ($script:loggedIn) {
                return 'cb({"result":1,"list":[{"online_ip":"192.0.2.10","user_account":"student"}]})'
            }
            return 'cb({"result":1,"list":[]})'
        }
        if ($Url -match '/portal/login\?') {
            $script:loggedIn = $true
            return 'cb({"result":1})'
        }
        throw 'Unexpected Dr.COM request.'
    }
    Assert (Invoke-DrcomLogin $Config.Campus) 'Dr.COM login/online confirmation failed.'
    Assert ($script:requests.Count -eq 4) 'Dr.COM did not confirm online after login.'
    $differentDevice = [pscustomobject]@{result=1;list=@([pscustomobject]@{online_ip='192.0.2.99';user_account='student'})}
    Assert (-not (Test-DrcomOnline $differentDevice '192.0.2.10' 'student')) 'Another device incorrectly confirmed Dr.COM login.'
    $missingSession = [pscustomobject]@{result=1;list=@()}
    Assert (-not (Test-DrcomOnline $missingSession '192.0.2.10' 'student')) 'A successful reply without an online session was accepted.'
    $genericReplyRejected = $false
    try { Test-DrcomOnline ([pscustomobject]@{result=1}) '192.0.2.10' 'student' }
    catch { $genericReplyRejected = $true }
    Assert $genericReplyRejected 'Dr.COM login reply was treated as online confirmation.'

    # Execute the actual top-level flow with OS operations replaced by fakes.
    . ([scriptblock]::Create((Get-FunctionSource $runtimeAst)))
    $flowSource = $runtimeAst.EndBlock.Statements[-1].Extent.Text.Replace('exit 0', 'return 0').Replace('exit 1', 'return 1')
    $flow = [scriptblock]::Create($flowSource)
    function Read-Config { param([string]$Path) return $script:caseConfig }
    function Write-Log { param([string]$Message) $script:events.Add('log') }
    function Get-CurrentSsid { return $script:currentSsid }
    function Wait-SsidVisible { param([string]$Ssid, [int]$TimeoutSeconds) return $script:visible }
    function Wait-ForSsid { param([string]$Ssid, [int]$TimeoutSeconds) return $true }
    function Ensure-WlanProfile { param($Campus) $script:events.Add('profile') }
    function Invoke-CampusLogin {
        param($Campus)
        $script:events.Add('auth')
        if ($script:rejectAuth) { throw 'Simulated login rejection.' }
        if ($script:dropAfterAuth) { $script:currentSsid = 'other-network' }
        return $true
    }
    function Start-Vpn { param($Vpn) $script:events.Add('vpn') }
    function netsh {
        $script:events.Add('connect')
        $global:LASTEXITCODE = 0
        $script:currentSsid = 'TestCampus'
    }
    $ProjectRoot = $testRoot
    $ConfigPath = Join-Path $testRoot 'config.json'
    foreach ($case in @('absent', 'visible', 'connected', 'auth-failed', 'disconnected', 'disabled')) {
        $script:caseConfig = Get-Content -Raw (Join-Path $root 'config.example.json') | ConvertFrom-Json
        $script:caseConfig.Campus.Ssid = 'TestCampus'
        $script:caseConfig.Runtime.StartupDelaySeconds = 0
        $script:caseConfig.Campus.Enabled = ($case -ne 'disabled')
        $script:currentSsid = if ($case -eq 'absent') { 'other-network' } else { 'TestCampus' }
        if ($case -eq 'visible') { $script:currentSsid = 'other-network' }
        $script:visible = ($case -ne 'absent')
        $script:rejectAuth = ($case -eq 'auth-failed')
        $script:dropAfterAuth = ($case -eq 'disconnected')
        $script:events = New-Object 'Collections.Generic.List[string]'
        $code = & $flow
        switch ($case) {
            'absent' { Assert ($code -eq 0 -and $script:events.Count -eq 0) 'Absent Wi-Fi caused a side effect.' }
            'disabled' { Assert ($code -eq 0 -and $script:events.Count -eq 0) 'Disabled campus automation caused a side effect.' }
            'visible' { Assert ($code -eq 0 -and ($script:events -join ',') -match 'profile,connect,log,auth,vpn') 'Visible Wi-Fi did not connect/authenticate/start VPN in order.' }
            'connected' { Assert ($code -eq 0 -and $script:events -contains 'vpn' -and $script:events -notcontains 'connect') 'An existing Wi-Fi connection skipped authentication or unnecessarily reconnected.' }
            default { Assert ($code -eq 1 -and $script:events -notcontains 'vpn') 'Failed authentication or disconnected Wi-Fi started VPN.' }
        }
    }

    . ([scriptblock]::Create((Get-FunctionSource $setupAst)))
    $ordinary = ConvertTo-SrunSettings 'http://192.0.2.1/login'
    Assert (-not $ordinary.AcId) 'Setup guessed an ac_id.'
    Assert ((ConvertTo-SrunSettings 'http://192.0.2.1/srun_portal_pc?ac_id=3').AcId -eq '3') 'Setup did not extract ac_id.'
    function Get-HttpRedirect {
        param([string]$Url)
        return [pscustomobject]@{StatusCode=200;Content='<html>other login</html>';Location=''}
    }
    Assert (-not (Test-SrunPortal $ordinary)) 'An HTML portal was misidentified as SRun.'
    function Get-HttpRedirect {
        param([string]$Url)
        return [pscustomobject]@{StatusCode=200;Content='cb({"error":"not_online_error","online_ip":"192.0.2.10"})';Location=''}
    }
    Assert (Test-SrunPortal $ordinary) 'A recognized SRun endpoint was not detected.'

    function Get-VisibleSsids { return @() }
    function Get-CurrentSsid { return 'OtherNetwork' }
    function Set-VpnConfiguration { param($Config) $Config.Vpn.Enabled = $false }
    function Read-Host {
        param([string]$Prompt)
        if ($script:answers.Count -eq 0) { throw 'Unexpected setup question.' }
        return $script:answers.Dequeue()
    }
    function Ensure-OpenWlanProfile { throw 'Offline setup attempted a Wi-Fi change.' }
    $script:answers = New-Object 'Collections.Generic.Queue[string]'
    foreach ($answer in @('TestCampus', '', '', '1', 'http://192.0.2.1', '', '3', 'student')) {
        $script:answers.Enqueue($answer)
    }
    $wizardConfig = New-UserConfiguration -TemplatePath (Join-Path $root 'config.example.json')
    Assert ($wizardConfig.Campus.Ssid -eq 'TestCampus' -and $wizardConfig.Campus.AcId -eq '3') 'Offline SRun setup did not save required settings.'
    Assert ($script:answers.Count -eq 0) 'Offline setup did not consume expected questions.'

    $SourceRoot = $root
    $ProjectRoot = Join-Path $testRoot 'installation'
    Copy-ProjectFiles
    Copy-ProjectFiles
    Assert (Test-Path (Join-Path $ProjectRoot 'src\SrunCrypto.cs')) 'Repeated installation lost SRun crypto.'
    Assert (-not (Test-Path (Join-Path $ProjectRoot 'src\src'))) 'Repeated installation nested the src directory.'
    foreach ($entry in @('QuickSetup.cmd','TestConnection.cmd','Uninstall-CampusNet.cmd','Uninstall-CampusNet.ps1','README.md','README.zh-CN.md','LICENSE')) {
        Assert (Test-Path (Join-Path $ProjectRoot $entry)) "Missing installed entry point: $entry"
    }
    $savedConfig = Join-Path $ProjectRoot 'config.json'
    $wizardConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $savedConfig -Encoding UTF8
    Copy-ProjectFiles
    Assert ((Get-Content -Raw -LiteralPath $savedConfig | ConvertFrom-Json).Campus.Username -eq 'student') 'Updating program files overwrote user settings.'

    # Load CDXML functions before mocking; autoload would replace the test double.
    Import-Module ScheduledTasks
    # Construct real task objects, but intercept the call that would register them.
    $TaskName = 'CampusNet Offline Test'
    function Register-ScheduledTask {
        param($TaskName, $Action, $Trigger, $Settings, $Principal, $Description, [switch]$Force)
        $script:taskDefinition = [pscustomobject]@{
            TaskName = $TaskName
            Action = $Action
            Trigger = $Trigger
            Settings = $Settings
            Principal = $Principal
        }
        return $script:taskDefinition
    }
    $null = Register-LogonTask -Root $ProjectRoot
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Assert ($script:taskDefinition.Trigger.UserId -eq $currentUser) 'Logon trigger did not target the installing user.'
    Assert ($script:taskDefinition.Principal.UserId -eq $currentUser) 'Task principal did not match the logon trigger.'
    Assert ($script:taskDefinition.Action.Arguments.Contains('"' + (Join-Path $ProjectRoot 'CampusNet-AutoConnect.ps1') + '"')) 'Task script path was not quoted.'
    Assert ($script:taskDefinition.Action.WorkingDirectory -eq $ProjectRoot) 'Task working directory was lost.'
    Assert (-not $script:taskDefinition.Settings.DisallowStartIfOnBatteries -and -not $script:taskDefinition.Settings.StopIfGoingOnBatteries) 'Battery power would prevent campus startup.'

    . ([scriptblock]::Create((Get-FunctionSource $runtimeAst)))
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CampusNetArgumentTest {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CommandLineToArgvW(string text, out int count);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);
    public static string[] Split(string text) {
        int count;
        IntPtr memory = CommandLineToArgvW(text, out count);
        if (memory == IntPtr.Zero) throw new Exception("Argument parsing failed.");
        try {
            string[] result = new string[count];
            for (int i = 0; i < count; i++)
                result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory, i * IntPtr.Size));
            return result;
        } finally { LocalFree(memory); }
    }
}
'@
    $arguments = @('C:\VPN Profiles\student.conf', 'campus vpn', 'a"b', 'C:\A B\', '', '&literal')
    $roundTrip = [CampusNetArgumentTest]::Split('client.exe ' + (ConvertTo-WindowsArguments $arguments))
    Assert ($roundTrip.Count -eq $arguments.Count + 1) 'VPN argument count changed.'
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        Assert ($roundTrip[$i + 1] -ceq $arguments[$i]) 'Windows altered a VPN argument.'
    }

    $profileDirectory = Join-Path $testRoot 'VPN Profiles'
    New-Item -ItemType Directory -Path $profileDirectory | Out-Null
    $profilePath = Join-Path $profileDirectory 'student.ovpn'
    Set-Content -LiteralPath $profilePath -Value '# Offline test profile'
    function Find-Executable { param($Configured, $Candidates) return 'vpn-test.exe' }
    function Start-Process {
        param($FilePath, $ArgumentList, [switch]$PassThru, $WindowStyle, $WorkingDirectory)
        $script:vpnCommand = [CampusNetArgumentTest]::Split('client.exe ' + $ArgumentList)
        $script:vpnWorkingDirectory = $WorkingDirectory
        $fakeProcess = [pscustomobject]@{HasExited=$false;ExitCode=0}
        $fakeProcess | Add-Member -MemberType ScriptMethod -Name Refresh -Value {}
        return $fakeProcess
    }
    function Write-Log { param([string]$Message) }
    $vpnConfig = [pscustomobject]@{
        OpenVPN = [pscustomobject]@{
            Executable = 'vpn-test.exe'
            ProfilePath = $profilePath
            Arguments = @('--config', '{profile}')
        }
    }
    foreach ($format in @('array', 'legacy-string')) {
        if ($format -eq 'legacy-string') { $vpnConfig.OpenVPN.Arguments = '--config "{profile}"' }
        Start-OpenVpn -Vpn $vpnConfig
        Assert ($script:vpnCommand.Count -eq 3 -and $script:vpnCommand[1] -eq '--config' -and $script:vpnCommand[2] -ceq $profilePath) "OpenVPN arguments failed for $format settings."
        Assert ($script:vpnWorkingDirectory -ceq $profileDirectory) 'OpenVPN relative files would use the wrong working directory.'
    }

    function Get-Service {
        param($Name, $ErrorAction)
        if ($script:tunnelExists) { return [pscustomobject]@{Name=$Name} }
    }
    function Set-Service {
        param($Name, $StartupType, $ErrorAction)
        Assert ($Name -ceq 'WireGuardTunnel$student' -and $StartupType -eq 'Manual') 'WireGuard would bypass campus authentication at the next boot.'
        $script:tunnelEvents.Add('manual')
    }
    function Start-Service {
        param($Name, $ErrorAction)
        Assert ($Name -ceq 'WireGuardTunnel$student') 'Wrong WireGuard tunnel was started.'
        $script:tunnelEvents.Add('start')
    }
    function Invoke-VpnCommand {
        param($Executable, $Arguments)
        Assert ($Arguments[0] -eq '/installtunnelservice' -and $Arguments[1] -ceq $profilePath) 'WireGuard install arguments changed.'
        $script:tunnelEvents.Add('install')
    }
    $vpnConfig = [pscustomobject]@{
        WireGuard = [pscustomobject]@{
            Executable = 'vpn-test.exe'
            ConfigPath = $profilePath
            TunnelName = 'student'
        }
    }
    foreach ($exists in @($false, $true)) {
        $script:tunnelExists = $exists
        $script:tunnelEvents = New-Object 'Collections.Generic.List[string]'
        Start-WireGuard -Vpn $vpnConfig
        $expected = if ($exists) { 'manual,start' } else { 'install,manual,start' }
        Assert (($script:tunnelEvents -join ',') -ceq $expected) 'WireGuard service startup order changed.'
    }
    Write-Host "PASS: $passed focused offline checks. No real network, proxy, VPN or task was changed."
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
