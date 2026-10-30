# 实现参考与范围

本项目在 2026-10-27 对比了以下公开项目的认证流程、依赖和协议限制。没有把这些项目作为安装依赖或捆绑分发，使用者只需 Windows 自带的 PowerShell。

| 项目 | 许可证 | 比较的设计 |
| --- | --- | --- |
| [BitSrunLoginGo](https://github.com/Mmx233/BitSrunLoginGo) | AGPL-3.0 | 深澜 challenge、JSONP 状态查询、服务器报告的客户端 IP |
| [srun](https://github.com/zu1k/srun) | GPL-3.0 | 深澜 `srun_bx1` 参数和加密算法校验 |
| [ZZU.Py](https://github.com/Illustar0/ZZU.Py) | MIT | ePortal 不同学校的账号前缀、密码编码、接口端口差异 |
| [drcom4scut](https://github.com/SeaLoong/drcom4scut) | LGPL-3.0 | 登录响应之后继续查询在线设备，匹配本机 IP 才确认联网 |

深澜适配使用 `get_challenge`、`srun_portal` 和 `rad_user_info`。Dr.COM 适配限定为 `drcom/chkstatus`、`eportal/portal/login` 和 `eportal/portal/online_list` 网页接口。它不实现 Dr.COM UDP 客户端协议。

设计选择：

- 只有目标 Wi-Fi 被检测到或已经连接，才允许进入认证流程。
- 认证请求不使用系统 HTTP 代理，不自动跟随凭据请求的重定向。
- 不记录请求 URL、认证正文或服务器原样错误消息，避免日志包含凭据。
- 在线状态确认失败、学校返回不兼容的页面或 Wi-Fi 中途断开，都跳过 VPN。
- 使用本机 DPAPI 保存密码，以当前用户交互登录的计划任务运行。

已知限制：

- 学校的接口路径、加密版本、验证码、账号后缀可能不同，无法保证所有学校通用。
- Dr.COM 目前支持原始或 Base64 密码，不支持各校自定义 XOR、RSA 或短信流程。
- 校园网认证接口如只提供 HTTP，传输保护取决于学校协议；Base64 不提供传输加密。
- 客户端启动或命令返回成功，不等于远端 VPN 隧道已经握手成功。
- 开机任务执行一次；未实现全天断线监控或自动关闭其他软件的自启动。
