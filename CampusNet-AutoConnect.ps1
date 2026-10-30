[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Once,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'

function Resolve-ConfiguredPath {
    param([string]$Path, [string]$BasePath)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw 'Missing config.json. Run QuickSetup.cmd first.'
    }
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)
$ProjectRoot = Split-Path -Parent $ConfigPath
$LogPath = Join-Path $ProjectRoot 'runtime\campusnet.log'

function Write-Log {
    param([string]$Message)
    $logDirectory = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
    }
    Add-Content -LiteralPath $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

function Get-CurrentSsid {
    $text = netsh wlan show interfaces 2>$null | Out-String
    $match = [regex]::Match($text, '(?m)^\s*SSID\s*:\s*(.+?)\s*$')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Test-SsidVisible {
    param([string]$Ssid)
    $text = netsh wlan show networks mode=bssid 2>$null | Out-String
    return [regex]::IsMatch($text, '(?m)^\s*SSID\s+\d+\s*:\s*' + [regex]::Escape($Ssid) + '\s*$')
}

function Wait-SsidVisible {
    param([string]$Ssid, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-CurrentSsid) -ceq $Ssid -or (Test-SsidVisible -Ssid $Ssid)) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Wait-ForSsid {
    param([string]$Ssid, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-CurrentSsid) -ceq $Ssid) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Ensure-WlanProfile {
    param($Campus)
    $ssid = [string]$Campus.Ssid
    $profileName = if ($Campus.ProfileName) { [string]$Campus.ProfileName } else { $ssid }
    $null = & netsh wlan show profile "name=$profileName" 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    if (-not $Campus.CreateOpenProfile) {
        throw "Windows has no saved Wi-Fi profile named '$profileName'. Connect once manually or enable CreateOpenProfile for an open campus network."
    }

    $escaped = [System.Security.SecurityElement]::Escape($ssid)
    $escapedProfile = [System.Security.SecurityElement]::Escape($profileName)
    $xml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$escapedProfile</name>
  <SSIDConfig><SSID><name>$escaped</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType>
  <connectionMode>manual</connectionMode>
  <MSM><security>
    <authEncryption>
      <authentication>open</authentication>
      <encryption>none</encryption>
      <useOneX>false</useOneX>
    </authEncryption>
  </security></MSM>
</WLANProfile>
"@
    $profilePath = Join-Path ([System.IO.Path]::GetTempPath()) ('campusnet-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        Set-Content -LiteralPath $profilePath -Value $xml -Encoding UTF8
        $output = & netsh wlan add profile "filename=$profilePath" user=current 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create an open Wi-Fi profile. netsh exit code: $LASTEXITCODE"
        }
        Write-Log "Created an open Wi-Fi profile for $ssid."
    }
    finally {
        Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-LocalIpv4 {
    param([string]$InterfaceAlias)
    if (-not $InterfaceAlias) {
        $ssid = Get-CurrentSsid
        if ($ssid) {
            $profile = Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $ssid } |
                Select-Object -First 1
            if ($profile) { $InterfaceAlias = [string]$profile.InterfaceAlias }
        }
    }
    if (-not $InterfaceAlias) {
        $wireless = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
            Where-Object { $_.NdisPhysicalMedium -eq 9 -and $_.Status -eq 'Up' })
        if ($wireless.Count -eq 1) { $InterfaceAlias = [string]$wireless[0].Name }
    }
    if (-not $InterfaceAlias) { return $null }
    $query = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' -and $_.AddressState -eq 'Preferred' }
    if ($InterfaceAlias) {
        $query = $query | Where-Object { $_.InterfaceAlias -eq $InterfaceAlias }
    }
    $address = $query | Sort-Object SkipAsSource | Select-Object -First 1
    if ($address) { return $address.IPAddress }
    return $null
}

function Wait-CampusIpv4 {
    param([string]$InterfaceAlias)
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $ip = Get-LocalIpv4 -InterfaceAlias $InterfaceAlias
        if ($ip) { return $ip }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw 'The campus Wi-Fi did not receive an IPv4 address. Check Campus.InterfaceAlias if using multiple wireless adapters.'
}

function Invoke-DirectGet {
    param([string]$Url)
    $response = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $false
        $request.Proxy = $null
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        if ($Config.Campus.PortalBase) { $request.Referer = [string]$Config.Campus.PortalBase }
        $response = $request.GetResponse()
    }
    catch { throw 'Could not reach the configured campus authentication server.' }
    try {
        if ([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300) {
            return ''
        }
        $stream = $response.GetResponseStream()
        if (-not $stream) { return '' }
        $reader = New-Object System.IO.StreamReader($stream)
        try { return $reader.ReadToEnd() }
        finally { $reader.Dispose() }
    }
    finally { $response.Close() }
}

function ConvertFrom-Jsonp {
    param([string]$Payload)
    $text = $Payload.Trim()
    $match = [regex]::Match(
        $text,
        '^[\w.$]+\s*\((?<json>\{.*\})\)\s*;?$',
        [Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($match.Success) { $text = $match.Groups['json'].Value }
    if (-not $text.StartsWith('{') -or -not $text.EndsWith('}')) {
        throw 'The campus authentication response format was not recognized.'
    }
    try { return ($text | ConvertFrom-Json) }
    catch { throw 'SRun response format was not recognized.' }
}

function Get-JsonpPayload {
    param([string]$Url)
    return (ConvertFrom-Jsonp -Payload (Invoke-DirectGet -Url $Url))
}

function Test-SrunOnline {
    param($Status, [string]$Username)
    if (-not $Status -or [string]$Status.error -ne 'ok') { return $false }
    $reportedUser = if ($Status.PSObject.Properties['user_name']) {
        [string]$Status.user_name
    }
    elseif ($Status.PSObject.Properties['username']) {
        [string]$Status.username
    }
    else { '' }
    return ($reportedUser -ceq $Username)
}

function Get-Password {
    $credentialPath = Resolve-ConfiguredPath -Path 'credentials.secure' -BasePath $ProjectRoot
    if (-not (Test-Path -LiteralPath $credentialPath)) {
        throw 'Missing credentials.secure. Run Install-CampusNet.ps1 on this computer.'
    }
    $secure = Get-Content -Raw -LiteralPath $credentialPath | ConvertTo-SecureString
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Invoke-SrunLogin {
    param($Campus)
    $cryptoPath = Join-Path $PSScriptRoot 'src\SrunCrypto.cs'
    if (-not ('CampusNetSrunCrypto' -as [type])) { Add-Type -Path $cryptoPath }
    $base = $Campus.PortalBase.TrimEnd('/')
    $portalPath = if ($Campus.PortalPath) { $Campus.PortalPath.Trim('/') } else { 'cgi-bin' }
    $infoUrl = "$base/$portalPath/rad_user_info"
    try {
        $status = Get-JsonpPayload -Url "${infoUrl}?callback=campusnet_status"
        if (Test-SrunOnline -Status $status -Username ([string]$Campus.Username)) {
            Write-Log 'Campus account is already online.'
            return $true
        }
    }
    catch {
        Write-Log 'Could not read the initial SRun status; trying the login flow.'
    }

    $ip = [string]$status.client_ip
    if (-not $ip) { $ip = [string]$status.online_ip }
    if (-not $ip) { $ip = Wait-CampusIpv4 -InterfaceAlias $Campus.InterfaceAlias }
    if (-not $ip) { throw 'Could not determine the local IPv4 address.' }
    if ($Once) { Write-Host '正在向深澜认证平台提交登录请求...' }
    $callback = 'campusnet_' + [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    $challengeUrl = "$base/$portalPath/get_challenge?username=$([uri]::EscapeDataString([string]$Campus.Username))&ip=$([uri]::EscapeDataString($ip))&callback=$callback"
    $challenge = Get-JsonpPayload -Url $challengeUrl
    if (($challenge.error -ne 'ok' -and $challenge.res -ne 'ok') -or -not $challenge.challenge) {
        throw 'Could not obtain the SRun challenge.'
    }
    if ($challenge.client_ip) { $ip = [string]$challenge.client_ip }
    elseif ($challenge.online_ip) { $ip = [string]$challenge.online_ip }
    $password = Get-Password

    $token = [string]$challenge.challenge
    $hmd5 = [CampusNetSrunCrypto]::HmacMd5($token, $password)
    $json = [ordered]@{
        username = [string]$Campus.Username
        password = $password
        ip = $ip
        acid = [string]$Campus.AcId
        enc_ver = 'srun_bx1'
    } | ConvertTo-Json -Compress
    $encodedInfo = [CampusNetSrunCrypto]::SrunInfo($json, $token)
    $check = $token + $Campus.Username + $token + $hmd5 + $token + $Campus.AcId + $token + $ip + $token + '200' + $token + '1' + $token + $encodedInfo
    $checksum = [CampusNetSrunCrypto]::Sha1($check)
    $query = @(
        'action=login'
        "username=$([uri]::EscapeDataString([string]$Campus.Username))"
        "password=$([uri]::EscapeDataString('{MD5}' + $hmd5))"
        'os=Windows%20NT'
        'name=Windows'
        'double_stack=0'
        "chksum=$checksum"
        "info=$([uri]::EscapeDataString($encodedInfo))"
        "ac_id=$([uri]::EscapeDataString([string]$Campus.AcId))"
        "ip=$([uri]::EscapeDataString($ip))"
        'n=200'
        'type=1'
        "callback=$callback"
    ) -join '&'

    $auth = Get-JsonpPayload -Url "$base/$portalPath/srun_portal?$query"
    if ($auth.error -ne 'ok' -and $auth.res -ne 'ok' -and $auth.suc_msg -ne 'login_ok') {
        throw 'SRun login request was rejected.'
    }
    Write-Log 'Campus login request submitted.'

    $authWaitSeconds = [int]$Config.Runtime.AuthWaitSeconds
    if ($authWaitSeconds -le 0) { $authWaitSeconds = 45 }
    $deadline = (Get-Date).AddSeconds($authWaitSeconds)
    do {
        Start-Sleep -Seconds 2
        try {
            $status = Get-JsonpPayload -Url "${infoUrl}?callback=campusnet_status"
            if (Test-SrunOnline -Status $status -Username ([string]$Campus.Username)) {
                Write-Log 'Campus authentication confirmed.'
                if ($Once) { Write-Host '校园网认证成功。' }
                return $true
            }
        }
        catch {
            Write-Log 'Waiting for campus authentication confirmation.'
        }
    } while ((Get-Date) -lt $deadline)

    throw 'Campus login was not confirmed by the SRun status endpoint. The VPN was not started.'
}

function ConvertTo-PortalQuery {
    param([System.Collections.IDictionary]$Parameters)
    return (($Parameters.GetEnumerator() | ForEach-Object {
        [Uri]::EscapeDataString([string]$_.Key) + '=' + [Uri]::EscapeDataString([string]$_.Value)
    }) -join '&')
}

function ConvertTo-Ipv4Number {
    param([string]$Ip)
    $address = $null
    if (-not [Net.IPAddress]::TryParse($Ip, [ref]$address) -or
        $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw 'The portal did not report a usable IPv4 address.'
    }
    $bytes = $address.GetAddressBytes()
    return ([uint64]$bytes[0] * 16777216 + [uint64]$bytes[1] * 65536 +
        [uint64]$bytes[2] * 256 + [uint64]$bytes[3])
}

function Test-DrcomOnline {
    param($Status, [string]$Ip, [string]$Username, [string]$AccountPrefix = '')
    if ([string]$Status.result -ne '1' -or -not $Status.PSObject.Properties['list']) {
        throw 'The Dr.COM online-session response was not recognized.'
    }
    $ipNumber = [string](ConvertTo-Ipv4Number -Ip $Ip)
    foreach ($session in @($Status.list)) {
        if ([string]$session.online_ip -ne $Ip -and [string]$session.online_ip -ne $ipNumber) { continue }
        $reportedAccount = [string]$session.user_account
        if ($AccountPrefix -and $reportedAccount.StartsWith($AccountPrefix, [StringComparison]::Ordinal)) {
            $reportedAccount = $reportedAccount.Substring($AccountPrefix.Length)
        }
        if ($reportedAccount -and $reportedAccount -cne $Username) {
            throw 'The current campus session belongs to another account. Disconnect it manually first.'
        }
        return $true
    }
    return $false
}

function Invoke-DrcomLogin {
    param($Campus)
    $base = ([string]$Campus.PortalBase).TrimEnd('/')
    $api = ([string]$Campus.Drcom.ApiBase).TrimEnd('/')
    $baseUri = [Uri]$base
    $apiUri = [Uri]$api
    if (-not $apiUri.IsAbsoluteUri -or $apiUri.Scheme -notin @('http', 'https') -or
        $apiUri.Host -ne $baseUri.Host -or ($baseUri.Scheme -eq 'https' -and $apiUri.Scheme -ne 'https')) {
        throw 'Dr.COM API must use the configured portal host without an HTTPS downgrade.'
    }

    $ip = Wait-CampusIpv4 -InterfaceAlias $Campus.InterfaceAlias
    $identity = Get-JsonpPayload -Url "$base/drcom/chkstatus?callback=campusnet_identity"
    foreach ($field in @('v46ip', 'client_ip', 'online_ip', 'lip')) {
        if ($identity.$field) { $ip = [string]$identity.$field; break }
    }
    $ipNumber = ConvertTo-Ipv4Number -Ip $ip
    $statusQuery = ConvertTo-PortalQuery -Parameters ([ordered]@{
        callback = 'campusnet_status'
        user_account = ''
        user_password = '123'
        wlan_user_ip = $ipNumber
        curr_user_ip = $ipNumber
        wlan_user_mac = '000000000000'
        jsVersion = '4.1.3'
        lang = 'zh'
    })
    $statusUrl = "$api/eportal/portal/online_list?$statusQuery"
    $status = Get-JsonpPayload -Url $statusUrl
    if (Test-DrcomOnline -Status $status -Ip $ip -Username $Campus.Username -AccountPrefix $Campus.Drcom.AccountPrefix) {
        Write-Log 'Campus account is already online.'
        return $true
    }

    $password = Get-Password
    switch ([string]$Campus.Drcom.PasswordEncoding) {
        'Plain' { }
        'Base64' { $password = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($password)) }
        default { throw 'Unsupported Dr.COM password encoding. Use Plain or Base64.' }
    }
    $query = ConvertTo-PortalQuery -Parameters ([ordered]@{
        callback = 'campusnet_login'
        login_method = '1'
        user_account = [string]$Campus.Drcom.AccountPrefix + [string]$Campus.Username
        user_password = $password
        wlan_user_ip = $ip
        wlan_user_ipv6 = ''
        wlan_user_mac = '000000000000'
        wlan_ac_ip = [string]$Campus.Drcom.AcIp
        wlan_ac_name = ''
        jsVersion = '4.1.3'
        terminal_type = '1'
        lang = 'zh-cn'
    })
    $reply = Get-JsonpPayload -Url "$api/eportal/portal/login?$query"
    if ([string]$reply.result -ne '1') { throw 'Dr.COM rejected the login request.' }
    Write-Log 'Campus login request submitted.'
    $timeout = [int]$Config.Runtime.AuthWaitSeconds
    if ($timeout -le 0) { $timeout = 45 }
    $deadline = (Get-Date).AddSeconds($timeout)
    do {
        Start-Sleep -Seconds 2
        $status = Get-JsonpPayload -Url $statusUrl
        if (Test-DrcomOnline -Status $status -Ip $ip -Username $Campus.Username -AccountPrefix $Campus.Drcom.AccountPrefix) {
            Write-Log 'Campus authentication confirmed.'
            return $true
        }
    } while ((Get-Date) -lt $deadline)
    throw 'Dr.COM did not confirm this device online. The VPN was not started.'
}

function Invoke-CampusLogin {
    param($Campus)
    $adapter = if ($Campus.AuthAdapter) { [string]$Campus.AuthAdapter } else { 'SRun' }
    switch ($adapter) {
        'SRun' { return (Invoke-SrunLogin -Campus $Campus) }
        'Drcom' { return (Invoke-DrcomLogin -Campus $Campus) }
        default { throw "Unsupported campus authentication platform: $adapter" }
    }
}

function Set-SystemProxy {
    param([bool]$Enabled, [int]$Port)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($Enabled) {
        Set-ItemProperty -Path $key -Name ProxyServer -Value "127.0.0.1:$Port"
        Set-ItemProperty -Path $key -Name ProxyEnable -Type DWord -Value 1
    }
    else { Set-ItemProperty -Path $key -Name ProxyEnable -Type DWord -Value 0 }
    if (-not ('CampusNetWinInet' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CampusNetWinInet {
    [DllImport("wininet.dll", SetLastError = true)]
    public static extern bool InternetSetOption(IntPtr h, int option, IntPtr p, int length);
}
'@
    }
    [CampusNetWinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [CampusNetWinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

function Find-Executable {
    param([string]$Configured, [string[]]$Candidates)
    if ($Configured -and (Test-Path -LiteralPath $Configured)) { return $Configured }
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Invoke-VpnCommand {
    param([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $commandLine = ConvertTo-WindowsArguments -Arguments $Arguments
    $start = @{ FilePath = $Executable; PassThru = $true; WindowStyle = 'Hidden' }
    if ($commandLine) { $start.ArgumentList = $commandLine }
    $process = Start-Process @start
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        throw "VPN command timed out: $([System.IO.Path]::GetFileName($Executable))"
    }
    if ($process.ExitCode -ne 0) { throw "VPN command failed with exit code $($process.ExitCode)." }
}

function ConvertTo-WindowsArguments {
    param([string[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        $escaped = [regex]::Replace([string]$argument, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }
    return ($quoted -join ' ')
}

function Wait-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $connect = $client.BeginConnect($HostName, $Port, $null, $null)
            if ($connect.AsyncWaitHandle.WaitOne(1000, $false) -and $client.Connected) {
                $client.EndConnect($connect)
                return $true
            }
        }
        catch { }
        finally { $client.Dispose() }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Start-ClashVerge {
    param($Vpn, [int]$TimeoutSeconds)
    $exe = Find-Executable $Vpn.ClashVerge.Executable @(
        "$env:ProgramFiles\Clash Verge\clash-verge.exe",
        "$env:LOCALAPPDATA\Programs\Clash Verge\clash-verge.exe"
    )
    if (-not $exe) { throw 'Clash Verge executable was not found.' }
    if (-not (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $exe -WindowStyle Hidden | Out-Null
    }
    if ($Vpn.SetSystemProxy -and $Vpn.ClashVerge.Port) {
        if (-not (Wait-TcpPort -HostName '127.0.0.1' -Port ([int]$Vpn.ClashVerge.Port) -TimeoutSeconds $TimeoutSeconds)) {
            throw 'Clash Verge started, but its local proxy port did not become ready. The system proxy was left unchanged.'
        }
    }
    if ($Vpn.SetSystemProxy -and $Vpn.ClashVerge.Port) {
        Set-SystemProxy -Enabled $true -Port ([int]$Vpn.ClashVerge.Port)
    }
    Write-Log 'Clash Verge adapter completed.'
}

function Start-WireGuard {
    param($Vpn)
    $exe = Find-Executable $Vpn.WireGuard.Executable @(
        "$env:ProgramFiles\WireGuard\wireguard.exe",
        "${env:ProgramFiles(x86)}\WireGuard\wireguard.exe"
    )
    if (-not $exe -or -not $Vpn.WireGuard.ConfigPath) { throw 'WireGuard executable or ConfigPath is missing.' }
    $profile = Resolve-ConfiguredPath -Path $Vpn.WireGuard.ConfigPath -BasePath $ProjectRoot
    if (-not (Test-Path -LiteralPath $profile)) { throw 'WireGuard config file was not found.' }
    $name = if ($Vpn.WireGuard.TunnelName) { [string]$Vpn.WireGuard.TunnelName } else { [System.IO.Path]::GetFileNameWithoutExtension($profile) }
    $service = Get-Service -Name "WireGuardTunnel`$$name" -ErrorAction SilentlyContinue
    if (-not $service) {
        Invoke-VpnCommand -Executable $exe -Arguments @('/installtunnelservice', $profile)
    }
    $serviceName = "WireGuardTunnel`$$name"
    Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
    Start-Service -Name $serviceName -ErrorAction Stop
    Write-Log "WireGuard adapter completed for tunnel $name."
}

function Start-OpenVpn {
    param($Vpn)
    $exe = Find-Executable $Vpn.OpenVPN.Executable @(
        "$env:ProgramFiles\OpenVPN\bin\openvpn.exe",
        "${env:ProgramFiles(x86)}\OpenVPN\bin\openvpn.exe"
    )
    $profile = Resolve-ConfiguredPath -Path $Vpn.OpenVPN.ProfilePath -BasePath $ProjectRoot
    if (-not $exe -or -not (Test-Path -LiteralPath $profile)) { throw 'OpenVPN executable or ProfilePath is missing.' }
    if ($Vpn.OpenVPN.Arguments -is [string]) {
        # Older installations store an already-quoted command line.
        $commandLine = $Vpn.OpenVPN.Arguments.Replace('{profile}', $profile)
    }
    else {
        $arguments = @($Vpn.OpenVPN.Arguments | ForEach-Object { ([string]$_).Replace('{profile}', $profile) })
        $commandLine = ConvertTo-WindowsArguments -Arguments $arguments
    }
    $process = Start-Process -FilePath $exe -ArgumentList $commandLine -PassThru -WindowStyle Hidden -WorkingDirectory (Split-Path -Parent $profile)
    Start-Sleep -Seconds 2
    $process.Refresh()
    if ($process.HasExited -and $process.ExitCode -ne 0) {
        throw "OpenVPN exited with code $($process.ExitCode)."
    }
    Write-Log 'OpenVPN process started.'
}

function Start-Tailscale {
    param($Vpn)
    $exe = Find-Executable $Vpn.Tailscale.Executable @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )
    if (-not $exe) { throw 'Tailscale executable was not found.' }
    Invoke-VpnCommand -Executable $exe -Arguments ([string[]]$Vpn.Tailscale.Arguments)
    Write-Log 'Tailscale adapter completed.'
}

function Start-WindowsVpn {
    param($Vpn)
    if (-not $Vpn.WindowsVpn.ConnectionName) { throw 'Windows VPN ConnectionName is missing.' }
    Invoke-VpnCommand -Executable "$env:SystemRoot\System32\rasdial.exe" -Arguments @([string]$Vpn.WindowsVpn.ConnectionName)
    Write-Log 'Windows VPN adapter completed.'
}

function Start-CustomVpn {
    param($Vpn)
    $exe = Resolve-ConfiguredPath -Path $Vpn.Custom.Executable -BasePath $ProjectRoot
    if (-not $exe) { throw 'Custom VPN executable is missing.' }
    Invoke-VpnCommand -Executable $exe -Arguments ([string[]]$Vpn.Custom.Arguments)
    Write-Log 'Custom VPN adapter completed.'
}

function Start-Vpn {
    param($Vpn)
    switch ([string]$Vpn.Adapter) {
        'ClashVerge' { Start-ClashVerge -Vpn $Vpn -TimeoutSeconds ([int]$Config.Runtime.VpnWaitSeconds); break }
        'WireGuard' { Start-WireGuard -Vpn $Vpn; break }
        'OpenVPN' { Start-OpenVpn -Vpn $Vpn; break }
        'Tailscale' { Start-Tailscale -Vpn $Vpn; break }
        'WindowsVpn' { Start-WindowsVpn -Vpn $Vpn; break }
        'Custom' { Start-CustomVpn -Vpn $Vpn; break }
        default { throw "Unsupported VPN adapter: $($Vpn.Adapter)" }
    }
}

try {
    $Config = Read-Config -Path $ConfigPath
    $configuredLog = Resolve-ConfiguredPath -Path $Config.Runtime.LogPath -BasePath $ProjectRoot
    if ($configuredLog) { $LogPath = $configuredLog }
    if ($Config.Runtime.StartupDelaySeconds -gt 0) {
        Start-Sleep -Seconds ([int]$Config.Runtime.StartupDelaySeconds)
    }

    if (-not $Config.Campus.Enabled) {
        if ($Once) { Write-Host '校园网自动连接未启用，本次不做任何操作。' }
        exit 0
    }

    $ssid = [string]$Config.Campus.Ssid
    if (-not $ssid) { throw 'Campus SSID is empty. Run the setup wizard again.' }
    $alreadyConnected = ((Get-CurrentSsid) -ceq $ssid)
    $targetVisible = $alreadyConnected
    if (-not $targetVisible) {
        if ($Once) { Write-Host "正在查找校园 Wi-Fi：$ssid" }
        $targetVisible = Wait-SsidVisible -Ssid $ssid -TimeoutSeconds ([int]$Config.Runtime.NetworkWaitSeconds)
    }
    if (-not $targetVisible) {
        if ($Once) { Write-Host '没有发现指定校园 Wi-Fi，本次不做任何操作。' }
        exit 0
    }

    Write-Log 'Run started.'
    if (-not $alreadyConnected) {
        Ensure-WlanProfile -Campus $Config.Campus
        $interface = [string]$Config.Campus.InterfaceAlias
        $profileName = if ($Config.Campus.ProfileName) { [string]$Config.Campus.ProfileName } else { $ssid }
        $args = @('wlan', 'connect', "name=$profileName", "ssid=$ssid")
        if ($interface) { $args += "interface=$interface" }
        $null = & netsh @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Windows could not start connecting to '$ssid' (netsh exit code $LASTEXITCODE)."
        }
        $alreadyConnected = Wait-ForSsid -Ssid $ssid -TimeoutSeconds ([int]$Config.Runtime.SsidWaitSeconds)
    }

    $campusReady = $false
    if ($alreadyConnected) {
        Write-Log "Connected to campus Wi-Fi: $ssid"
        if ($Once) { Write-Host '已连接校园 Wi-Fi，正在完成网页认证...' }
        $campusReady = Invoke-CampusLogin -Campus $Config.Campus
    }
    else {
        throw "Connecting to '$ssid' timed out. Campus authentication and VPN startup were skipped."
    }

    if ($campusReady -and (Get-CurrentSsid) -cne $ssid) {
        throw 'The target campus Wi-Fi disconnected during authentication. The VPN was not started.'
    }
    if ($Config.Vpn.Enabled -and $campusReady) {
        if ($Once) { Write-Host "校园网已确认，正在启动 $($Config.Vpn.Adapter)..." }
        Start-Vpn -Vpn $Config.Vpn
    }
    elseif ($Config.Vpn.Enabled -and -not $campusReady) {
        Write-Log 'VPN startup skipped because campus authentication was not confirmed.'
        if ($Once) { Write-Host '校园网认证未确认，已跳过 VPN。' }
    }
    Write-Log 'Run completed.'
    if ($Once) { Write-Host '本次连接流程已结束。' }
    exit 0
}
catch {
    Write-Log ('Run failed: ' + $_.Exception.Message)
    if ($Once) { Write-Host ('连接失败：' + $_.Exception.Message); Write-Host "日志位置：$LogPath" }
    exit 1
}
finally {
    if ($PauseAtEnd) {
        [void](Read-Host '按 Enter 关闭此窗口')
    }
}

