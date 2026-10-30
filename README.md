# 校园网自动连接工具

> **注意：**
> - 运行此项目时请勿打开校园网。
> - 运行此项目时请关闭代理环境。
> - 有问题可以联系我 QQ：3416246182。

**校园网先连好，VPN 再自动开。开机后少点几下。**

[中文安装说明](README.zh-CN.md)

下载 ZIP、解压、双击 ‘QuickSetup.cmd’

1. 检查你指定的校园 / 公共 Wi-Fi，发现后连接。
2. 用你保存的账号、密码完成已适配的网页认证，并确认在线。
3. 启动所选的 VPN 或代理；Clash Verge 会在端口就绪后开启系统代理。

**没有指定 Wi-Fi 就结束，不切换网络、不改代理、不启动 VPN。认证失败也不会启动 VPN。**

## 第一次怎么用

1. 准备 Windows 10 / 11、校园网账号密码，以及已经能手动连接的 VPN 软件。
2. 在 GitHub 点击 **Code → Download ZIP**，先右键 ZIP 选择“全部解压”，再进入解压后的文件夹双击 `QuickSetup.cmd`。请不要在压缩包预览中直接运行。
3. 选择 Wi-Fi、认证平台和 VPN。向导会尝试识别深澜参数，识别不到时按提示补充学校的登录地址和参数。
4. 运行向导里的连接测试。设置完成后，下次登录 Windows 会自动检查目标 Wi-Fi。

无需安装 Python、Node.js 或另行下载运行环境。每个人都需要首次填写自己的信息。

| 网页认证 | 适用范围 |
| --- | --- |
| 深澜 / SRun | 常见 `srun_bx1`，需要登录地址和学校的 `ac_id` |
| Dr.COM / ePortal | `/eportal/portal/login`、`online_list` 网页接口，支持原始或 Base64 密码 |

不支持所有公共 Wi-Fi 或所有学校版本。验证码、短信、二维码登录、锐捷客户端及 Dr.COM 客户端协议暂不支持。

| VPN / 代理 | 首次准备 |
| --- | --- |
| Clash Verge | 安装并配置节点，确认本地 HTTP / 混合端口 |
| WireGuard | 准备 `.conf` 隧道配置 |
| OpenVPN Community | 准备无需交互输入的 `.ovpn` 配置 |
| Tailscale | 安装并手动登录一次 |
| Windows 自带 VPN | 在系统设置中保存可连接的 VPN |
| 自定义 | 提供软件的连接命令及参数 |

WireGuard、OpenVPN 需要以管理员身份运行设置；使用自己的 Windows 账号提权，密码文件绑定该账号。其他 VPN 软件的自启动可能让它提前运行，需要在其设置中关闭；本工具控制自己发起的连接。

使用 WireGuard 时，选中的隧道服务会设为手动启动，由本工具在校园网认证后启动。

## 本机文件

程序安装到 `%LOCALAPPDATA%\CampusNet-AutoConnect`。设置完成后可删除下载的解压目录。

- 再试一次：双击 `TestConnection.cmd`，会读取已安装的设置。
- 修改设置：再次双击 `QuickSetup.cmd`。
- 关闭自启动：双击 `Uninstall-CampusNet.cmd`，保留本机配置。
- 日志：安装目录中的 `runtime\campusnet.log`；找不到目标 Wi-Fi 时不写日志。

设置窗口会保留运行结果，按键后才关闭。如果出现错误，请先看窗口里的提示；提示文件缺失时，重新完整解压整个 ZIP。

密码使用 Windows DPAPI 加密。不要分享本机 `config.json`、`credentials.secure`、日志、VPN 配置、私钥或证书。

自动运行发生在**登录 Windows 后**；不会抢在系统登录前联网，也不会常驻监控全天断线。

## 验证与许可

离线检查：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Verify.ps1`。检查使用模拟网络，不提交真实账号或改系统网络。

本地模拟验证不等于已经在各学校、各 VPN 上实测。认证依赖学校接口，VPN 连接依赖你的现有软件、配置和权限。

MIT，见 [LICENSE](LICENSE)。

