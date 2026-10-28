[CmdletBinding()]
param(
    [string]$ProjectRoot = (Join-Path $env:LOCALAPPDATA 'CampusNet-AutoConnect'),
    [switch]$RegisterLogonTask,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
$SourceRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
$TaskName = 'CampusNet AutoConnect'

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text ==" -ForegroundColor Cyan
}

function Read-Default {
    param([string]$Prompt, [string]$Default = '')
    if ($Default) {
        $answer = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        return $answer.Trim()
    }
    return (Read-Host $Prompt).Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = (Read-Host "$Prompt ($hint)").Trim()
    if (-not $answer) { return $Default }
    return $answer -match '^(?i:y|yes|1)$'
}

function Copy-ProjectFiles {
    if ([string]::Equals($SourceRoot, $ProjectRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot 'CampusNet-AutoConnect.ps1'))) {
        throw 'Run this setup program from the extracted CampusNet-AutoConnect folder.'
    }

    New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
    foreach ($name in @(
        'CampusNet-AutoConnect.ps1',
        'Install-CampusNet.ps1',
        'config.example.json',
        'QuickSetup.cmd',
        'TestConnection.cmd',
        'Uninstall-CampusNet.ps1',
        'Uninstall-CampusNet.cmd',
        'README.md',
        'README.zh-CN.md',
        'LICENSE'
    )) {
        $source = Join-Path $SourceRoot $name
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $ProjectRoot $name) -Force
        }
    }
    $source = Join-Path $SourceRoot 'src'
    $destination = Join-Path $ProjectRoot 'src'
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -LiteralPath (Join-Path $source 'SrunCrypto.cs') -Destination $destination -Force
}

function Get-CurrentSsid {
    $text = & netsh.exe wlan show interfaces 2>$null | Out-String
    $match = [regex]::Match($text, '(?m)^\s*SSID\s*:\s*(.+?)\s*$')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Get-VisibleSsids {
    $text = & netsh.exe wlan show networks mode=bssid 2>$null | Out-String
    $items = [regex]::Matches($text, '(?m)^\s*SSID\s+\d+\s*:\s*(.*?)\s*$') |
        ForEach-Object { $_.Groups[1].Value.Trim() } |
        Where-Object { $_ } |
        Select-Object -Unique
    return @($items)
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

function Ensure-OpenWlanProfile {
    param($Campus)
    $ssid = [string]$Campus.Ssid
    $profileName = if ($Campus.ProfileName) { [string]$Campus.ProfileName } else { $ssid }
    $null = & netsh.exe wlan show profile "name=$profileName" 2>&1
    if ($LASTEXITCODE -eq 0) { return }
    if (-not $Campus.CreateOpenProfile) {
        throw "Windows has no saved Wi-Fi profile named '$profileName'. Connect to it once manually before setup."
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
  <MSM><security><authEncryption><authentication>open</authentication><encryption>none</encryption><useOneX>false</useOneX></authEncryption></security></MSM>
</WLANProfile>
"@
    $profilePath = Join-Path ([System.IO.Path]::GetTempPath()) ('campusnet-setup-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        Set-Content -LiteralPath $profilePath -Value $xml -Encoding UTF8
        $null = & netsh.exe wlan add profile "filename=$profilePath" user=current 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the open campus Wi-Fi profile.' }
    }
    finally { Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue }
}

function Get-HttpRedirect {
    param([string]$Url)
    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $false
    $request.Proxy = $null
    $request.Timeout = 6000
    $request.ReadWriteTimeout = 6000
    $request.UserAgent = 'CampusNet-AutoConnect-Setup'
    $response = $null
    try {
        $response = $request.GetResponse()
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
    }
    catch {
        return $null
    }
    if (-not $response) { return $null }
    try {
        $content = ''
        $stream = $response.GetResponseStream()
        if ($stream) {
            $reader = New-Object System.IO.StreamReader($stream)
            try { $content = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Location = [string]$response.Headers['Location']
            Content = $content
        }
    }
    finally { $response.Close() }
}

function ConvertFrom-PortalJsonp {
    param([string]$Payload)
    $text = $Payload.Trim()
    $match = [regex]::Match($text, '^[\w.$]+\s*\((?<json>\{.*\})\)\s*;?$', [Text.RegularExpressions.RegexOptions]::Singleline)
    if ($match.Success) { $text = $match.Groups['json'].Value }
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

function Test-SrunPortal {
    param($Settings)
    if (-not $Settings -or -not $Settings.PortalBase) { return $false }
    $portalPath = ([string]$Settings.PortalPath).Trim('/')
    if (-not $portalPath) { $portalPath = 'cgi-bin' }
    $url = "$($Settings.PortalBase.TrimEnd('/'))/$portalPath/rad_user_info?callback=campusnet_probe"
    $response = Get-HttpRedirect -Url $url
    if (-not $response -or $response.StatusCode -lt 200 -or $response.StatusCode -ge 300) { return $false }
    $status = ConvertFrom-PortalJsonp -Payload $response.Content
    if (-not $status -or -not $status.PSObject.Properties['error']) { return $false }
    foreach ($field in @('online_ip', 'srun_ver', 'server_flag', 'user_name', 'username')) {
        if ($status.PSObject.Properties[$field]) { return $true }
    }
    return $false
}

function ConvertTo-SrunSettings {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    try { $uri = [Uri]$Url.Trim() } catch { return $null }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https')) { return $null }

    $portalPath = '/cgi-bin'
    $cgiMatch = [regex]::Match($uri.AbsolutePath, '^(?<prefix>.*?/cgi-bin)(?:/|$)', 'IgnoreCase')
    if ($cgiMatch.Success) { $portalPath = $cgiMatch.Groups['prefix'].Value }

    $acId = ''
    $acMatch = [regex]::Match($uri.Query, '(?:^\?|&)ac_id=([^&]+)', 'IgnoreCase')
    if ($acMatch.Success) {
        $acId = [Uri]::UnescapeDataString($acMatch.Groups[1].Value)
    }
    if (-not $acId) {
        $indexMatch = [regex]::Match($uri.AbsolutePath, 'index_(\d+)\.html', 'IgnoreCase')
        if ($indexMatch.Success) { $acId = $indexMatch.Groups[1].Value }
    }
    return [pscustomobject]@{
        PortalBase = $uri.GetLeftPart([UriPartial]::Authority)
        PortalPath = $portalPath
        AcId = $acId
        RedirectUrl = $uri.AbsoluteUri
    }
}

function Find-SrunSettings {
    $probes = @(
        'http://www.msftconnecttest.com/connecttest.txt',
        'http://connect.rom.miui.com/generate_204',
        'http://captive.apple.com/hotspot-detect.html',
        'http://detectportal.firefox.com/success.txt'
    )
    foreach ($probe in $probes) {
        $response = Get-HttpRedirect -Url $probe
        if ($response -and $response.StatusCode -ge 300 -and $response.StatusCode -lt 400 -and $response.Location) {
            try {
                $target = [Uri]::new([Uri]$probe, [string]$response.Location)
                $settings = ConvertTo-SrunSettings -Url $target.AbsoluteUri
                if ($settings -and (Test-SrunPortal -Settings $settings)) { return $settings }
            }
            catch { }
        }
    }
    return $null
}

function Find-Executable {
    param([string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return ''
}

function Read-RequiredPath {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $value = Read-Default -Prompt $Prompt -Default $Default
        if (Test-Path -LiteralPath $value) {
            return [System.IO.Path]::GetFullPath($value)
        }
        Write-Host '没有找到这个文件，请输入完整路径。' -ForegroundColor Yellow
        $Default = ''
    }
}

function Set-VpnConfiguration {
    param($Config)

    $clashPath = Find-Executable @(
        "$env:ProgramFiles\Clash Verge\clash-verge.exe",
        "$env:LOCALAPPDATA\Programs\Clash Verge\clash-verge.exe"
    )
    $wireGuardPath = Find-Executable @(
        "$env:ProgramFiles\WireGuard\wireguard.exe",
        "${env:ProgramFiles(x86)}\WireGuard\wireguard.exe"
    )
    $openVpnPath = Find-Executable @(
        "$env:ProgramFiles\OpenVPN\bin\openvpn.exe",
        "${env:ProgramFiles(x86)}\OpenVPN\bin\openvpn.exe"
    )
    $tailscalePath = Find-Executable @(
        "$env:ProgramFiles\Tailscale\tailscale.exe",
        "${env:ProgramFiles(x86)}\Tailscale\tailscale.exe"
    )
    $vpnNames = @()
    if (Get-Command Get-VpnConnection -ErrorAction SilentlyContinue) {
        try { $vpnNames = @(Get-VpnConnection -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) } catch { }
    }

    Write-Step '选择你已经安装并登录好的 VPN 或代理软件'
    $options = @(
        @{ Key = 'ClashVerge'; Label = 'Clash Verge'; Found = [bool]$clashPath },
        @{ Key = 'WireGuard'; Label = 'WireGuard'; Found = [bool]$wireGuardPath },
        @{ Key = 'OpenVPN'; Label = 'OpenVPN'; Found = [bool]$openVpnPath },
        @{ Key = 'Tailscale'; Label = 'Tailscale'; Found = [bool]$tailscalePath },
        @{ Key = 'WindowsVpn'; Label = 'Windows 自带 VPN'; Found = [bool]$vpnNames.Count },
        @{ Key = 'Custom'; Label = '其他提供命令行连接方式的软件'; Found = $false },
        @{ Key = 'None'; Label = '暂不连接 VPN'; Found = $false }
    )
    for ($i = 0; $i -lt $options.Count; $i++) {
        $state = if ($options[$i].Found) { '已检测到' } else { '需要手动提供路径或设置' }
        Write-Host ('{0}. {1} ({2})' -f ($i + 1), $options[$i].Label, $state)
    }
    $choice = 0
    while ($choice -lt 1 -or $choice -gt $options.Count) {
        $raw = Read-Host '输入序号'
        if ($raw -match '^\d+$') { $choice = [int]$raw }
    }
    $adapter = $options[$choice - 1].Key
    if ($adapter -eq 'None') {
        $Config.Vpn.Enabled = $false
        return
    }

    $Config.Vpn.Enabled = $true
    $Config.Vpn.Adapter = $adapter
    switch ($adapter) {
        'ClashVerge' {
            if (-not $clashPath) { $clashPath = Read-RequiredPath 'Clash Verge 程序路径' }
            $Config.Vpn.ClashVerge.Executable = $clashPath
            $Config.Vpn.ClashVerge.Port = [int](Read-Default 'Clash Verge 的本地代理端口' '7897')
            $Config.Vpn.SetSystemProxy = Read-YesNo '代理端口就绪后自动打开 Windows 系统代理？' $true
        }
        'WireGuard' {
            if (-not $wireGuardPath) { $wireGuardPath = Read-RequiredPath 'WireGuard 程序路径' }
            $Config.Vpn.WireGuard.Executable = $wireGuardPath
            $Config.Vpn.WireGuard.ConfigPath = Read-RequiredPath 'WireGuard 隧道配置文件（.conf）路径'
            $Config.Vpn.WireGuard.TunnelName = [System.IO.Path]::GetFileNameWithoutExtension($Config.Vpn.WireGuard.ConfigPath)
        }
        'OpenVPN' {
            if (-not $openVpnPath) { $openVpnPath = Read-RequiredPath 'OpenVPN 程序路径' }
            $Config.Vpn.OpenVPN.Executable = $openVpnPath
            $Config.Vpn.OpenVPN.ProfilePath = Read-RequiredPath 'OpenVPN 配置文件（.ovpn）路径'
        }
        'Tailscale' {
            if (-not $tailscalePath) { $tailscalePath = Read-RequiredPath 'Tailscale 程序路径' }
            $Config.Vpn.Tailscale.Executable = $tailscalePath
            $Config.Vpn.Tailscale.Arguments = @('up')
        }
        'WindowsVpn' {
            if ($vpnNames.Count -gt 0) {
                Write-Host '已保存的 Windows VPN：'
                for ($i = 0; $i -lt $vpnNames.Count; $i++) {
                    Write-Host ('{0}. {1}' -f ($i + 1), $vpnNames[$i])
                }
            }
            $Config.Vpn.WindowsVpn.ConnectionName = Read-Default '要连接的 VPN 名称' $(if ($vpnNames.Count -gt 0) { $vpnNames[0] } else { '' })
        }
        'Custom' {
            $Config.Vpn.Custom.Executable = Read-RequiredPath 'VPN 命令程序完整路径'
            $arguments = @()
            $index = 1
            while ($true) {
                $argument = Read-Host "命令参数 $index（完成后直接回车）"
                if ([string]::IsNullOrEmpty($argument)) { break }
                $arguments += $argument
                $index++
            }
            $Config.Vpn.Custom.Arguments = @($arguments)
        }
    }
}

function Set-DrcomConfiguration {
    param($Config)
    Write-Step '设置 Dr.COM / ePortal 网页认证'
    Write-Host '连接学校 Wi-Fi 后，复制浏览器自动打开的登录页网址。未在学校时也可填写已知地址。'
    Add-Type -AssemblyName System.Web
    while ($true) {
        $url = Read-Default '粘贴学校登录页的完整网址' ''
        $uri = $null
        if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('http', 'https')) { break }
        Write-Host '请输入包含 http:// 或 https:// 的完整网址。' -ForegroundColor Yellow
    }
    $Config.Campus.PortalBase = $uri.GetLeftPart([UriPartial]::Authority)
    $query = [Web.HttpUtility]::ParseQueryString($uri.Query)
    $api = New-Object System.UriBuilder($Config.Campus.PortalBase)
    if ($uri.IsDefaultPort) { $api.Port = if ($uri.Scheme -eq 'https') { 802 } else { 801 } }
    $Config.Campus.Drcom.ApiBase = Read-Default '认证接口服务器地址（少数学校端口不同，按学校说明修改）' $api.Uri.GetLeftPart([UriPartial]::Authority)
    $Config.Campus.Drcom.AcIp = Read-Default '接入设备 wlanacip（未提供可留空）' ([string]$query['wlanacip'])
    $Config.Campus.Username = Read-Default '校园网完整账号（如果有 @运营商 后缀，请一起填写）' ''
    if (-not $Config.Campus.Username) { throw '校园网账号不能为空。' }
    Write-Host '有些学校在登录请求账号前加 ,0,，并将密码转成 Base64。请以本校说明为准。'
    if (Read-YesNo '本校登录请求需要 ,0, 账号前缀吗？' $false) {
        $Config.Campus.Drcom.AccountPrefix = ',0,'
    }
    if (Read-YesNo '本校登录请求需要 Base64 密码吗？' $false) {
        $Config.Campus.Drcom.PasswordEncoding = 'Base64'
    }
}

function New-UserConfiguration {
    param([string]$TemplatePath)
    $config = Get-Content -Raw -LiteralPath $TemplatePath | ConvertFrom-Json

    Write-Step '选择学校 Wi-Fi'
    $visible = @(Get-VisibleSsids)
    $current = Get-CurrentSsid
    if ($current -and $visible -notcontains $current) { $visible = @($current) + $visible }
    if ($visible.Count -gt 0) {
        for ($i = 0; $i -lt $visible.Count; $i++) {
            $suffix = if ($visible[$i] -eq $current) { '（当前已连接）' } else { '' }
            Write-Host ('{0}. {1} {2}' -f ($i + 1), $visible[$i], $suffix)
        }
        $choice = Read-Host '输入序号，或直接输入 Wi-Fi 名称'
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $visible.Count) {
            $ssid = $visible[[int]$choice - 1]
        }
        else { $ssid = $choice.Trim() }
    }
    else {
        Write-Host '暂时没有扫描到 Wi-Fi，请输入学校 Wi-Fi 名称。'
        $ssid = (Read-Host '学校 Wi-Fi 名称').Trim()
    }
    if (-not $ssid) { throw 'Wi-Fi 名称不能为空。' }
    $config.Campus.Ssid = $ssid
    $config.Campus.ProfileName = Read-Default 'Windows 中保存的 Wi-Fi 配置名称' $ssid
    $config.Campus.CreateOpenProfile = Read-YesNo '这是不需要 Wi-Fi 密码的公共校园网吗？' $true

    Write-Step '选择学校的网页认证平台'
    Write-Host '1. 深澜（SRun）'
    Write-Host '2. Dr.COM / ePortal（常见登录页为 a79.htm、a70.htm 等）'
    $platform = Read-Default '请选择；不确定时查看学校登录页或联系网络中心' '1'
    if ($platform -eq '2') {
        $config.Campus.AuthAdapter = 'Drcom'
        Set-DrcomConfiguration -Config $config
        Set-VpnConfiguration -Config $config
        return $config
    }
    if ($platform -ne '1') { throw '请选择已支持的认证平台：1 或 2。' }

    Write-Step '设置深澜自助认证'
    $portal = $null
    $connected = ((Get-CurrentSsid) -ceq $ssid)
    if (-not $connected) {
        $visible = @(Get-VisibleSsids)
        if ($visible -ccontains $ssid -and (Read-YesNo '现在连接这个 Wi-Fi，自动识别深澜登录页？' $true)) {
            Ensure-OpenWlanProfile -Campus $config.Campus
            $profileName = [string]$config.Campus.ProfileName
            $null = & netsh.exe wlan connect "name=$profileName" "ssid=$ssid" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $connected = Wait-ForSsid -Ssid $ssid -TimeoutSeconds 45
            }
        }
    }

    if ($connected) { $portal = Find-SrunSettings }
    if ($portal) {
        Write-Host "检测到登录跳转：$($portal.RedirectUrl)"
        if ($portal.AcId) { Write-Host "识别到接入点编号：$($portal.AcId)" }
    }
    else {
        if ($connected) {
            Write-Host '没有自动识别到深澜登录页。浏览器打开 http://neverssl.com，等登录页出现后复制地址栏网址。' -ForegroundColor Yellow
            if (Read-YesNo '现在打开登录页？' $true) { Start-Process 'http://neverssl.com' }
            $portalUrl = Read-Host '粘贴登录页完整网址；没有网址可直接回车手动填写'
            if ($portalUrl) { $portal = ConvertTo-SrunSettings -Url $portalUrl }
            if ($portal -and -not (Test-SrunPortal -Settings $portal)) {
                Write-Host '登录页地址看起来不像标准深澜接口，将保留手动填写的设置；首次测试可能无法认证。' -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "当前没有连接到 $ssid。可以先完成设置，之后开机检测到它时会自动连接并认证。" -ForegroundColor Yellow
        }
    }

    $baseDefault = if ($portal) { $portal.PortalBase } else { '' }
    $pathDefault = if ($portal) { $portal.PortalPath } else { '/cgi-bin' }
    $acidDefault = if ($portal) { $portal.AcId } else { '' }
    $config.Campus.PortalBase = Read-Default '深澜认证服务器地址（例如 http://10.0.0.1）' $baseDefault
    while ($true) {
        try {
            $baseUri = [Uri]$config.Campus.PortalBase
            if ($baseUri.IsAbsoluteUri -and $baseUri.Scheme -in @('http', 'https')) {
                $config.Campus.PortalBase = $baseUri.GetLeftPart([UriPartial]::Authority)
                break
            }
        }
        catch { }
        Write-Host '请输入包含 http:// 或 https:// 的完整服务器地址。' -ForegroundColor Yellow
        $config.Campus.PortalBase = Read-Default '深澜认证服务器地址' ''
    }
    $config.Campus.PortalPath = Read-Default '深澜接口路径' $pathDefault
    if (-not $config.Campus.PortalPath) { $config.Campus.PortalPath = '/cgi-bin' }
    $config.Campus.AcId = Read-Default '接入点编号 ac_id（网页登录地址中常见 ac_id=数字）' $acidDefault
    while ($config.Campus.AcId -notmatch '^\d+$') {
        Write-Host '请填写学校提供的数字 ac_id，不能直接猜一个值。' -ForegroundColor Yellow
        $config.Campus.AcId = Read-Default '接入点编号 ac_id' ''
    }
    $config.Campus.Username = (Read-Host '校园网账号/学号').Trim()
    if (-not $config.Campus.Username) { throw '校园网账号不能为空。' }

    Set-VpnConfiguration -Config $config
    return $config
}

function Save-CampusPassword {
    param([string]$Path)
    $securePassword = Read-Host '校园网密码（输入时不会显示）' -AsSecureString
    if ($securePassword.Length -eq 0) { throw '密码不能为空。' }
    $encrypted = ConvertFrom-SecureString -SecureString $securePassword
    Set-Content -LiteralPath $Path -Value $encrypted -Encoding UTF8
    Write-Host '密码已使用当前 Windows 账号的 DPAPI 加密保存。'
}

function Register-LogonTask {
    param([string]$Root)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $userId = $identity.Name
    $script = Join-Path $Root 'CampusNet-AutoConnect.ps1'
    $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $runLevel = if ($isAdmin) { 'Highest' } else { 'Limited' }
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel $runLevel
    $task = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Connect the selected campus Wi-Fi, confirm portal authentication, then start the selected VPN.' -Force
    return $task
}

try {
    Copy-ProjectFiles
    $configPath = Join-Path $ProjectRoot 'config.json'
    $examplePath = Join-Path $ProjectRoot 'config.example.json'
    $credentialPath = Join-Path $ProjectRoot 'credentials.secure'
    if (-not (Test-Path -LiteralPath $examplePath)) { throw 'config.example.json is missing from the downloaded folder.' }

    Write-Host 'CampusNet AutoConnect 首次设置' -ForegroundColor Cyan
    Write-Host "程序将安装到：$ProjectRoot"
    Write-Host '只有发现目标 Wi-Fi 并确认校园网认证成功后才会启动 VPN。'

    $reconfigure = $false
    if (Test-Path -LiteralPath $configPath) {
        Write-Step '发现已有设置'
        Write-Host '1. 保留设置并更新开机启动'
        Write-Host '2. 重新设置学校 Wi-Fi、认证账号和 VPN'
        $choice = Read-Default '请选择' '1'
        $reconfigure = ($choice -eq '2')
    }
    else { $reconfigure = $true }

    if ($reconfigure) {
        $config = New-UserConfiguration -TemplatePath $examplePath
        Save-CampusPassword -Path $credentialPath
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding UTF8
    }
    else {
        $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $credentialPath)) {
            Save-CampusPassword -Path $credentialPath
        }
    }

    if ($config.Vpn.Enabled -and $config.Vpn.Adapter -eq 'ClashVerge' -and $config.Vpn.SetSystemProxy) {
        Write-Host '提示：目标校园 Wi-Fi 不可用时，程序不会改动 Windows 系统代理。'
    }
    if ($config.Vpn.Enabled -and $config.Vpn.Adapter -in @('WireGuard', 'OpenVPN')) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) {
            throw '设置已保存。WireGuard / OpenVPN 需要管理员权限：请右键 QuickSetup.cmd，选择以管理员身份运行，再保留已有设置完成开机任务。'
        }
    }

    Write-Step '设置登录 Windows 后自动运行'
    $task = Register-LogonTask -Root $ProjectRoot
    Write-Host "已注册开机任务：$($task.TaskName)"

    if (Read-YesNo '现在运行一次连接测试？' $true) {
        $script = Join-Path $ProjectRoot 'CampusNet-AutoConnect.ps1'
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Once"
        $test = Start-Process -FilePath $powershell -ArgumentList $arguments -WorkingDirectory $ProjectRoot -PassThru -Wait
        if ($test.ExitCode -ne 0) {
            Write-Host '连接测试未成功；开机任务仍已设置。请查看 runtime\campusnet.log。' -ForegroundColor Yellow
        }
    }

    Write-Host ''
    Write-Host '设置完成。下次登录 Windows 时会自动检查指定 Wi-Fi。'
    Write-Host '无目标 Wi-Fi：不执行任何操作。目标 Wi-Fi：连接并完成网页认证后再启动 VPN。'
    Write-Host "本机配置保存在：$ProjectRoot"
}
catch {
    Write-Host ''
    Write-Host ('设置未完成：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
finally {
    if ($PauseAtEnd) {
        [void](Read-Host '按 Enter 关闭此窗口')
    }
}
