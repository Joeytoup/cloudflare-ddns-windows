
# Windows Cloudflare Direct DDNS

适用于 Windows 环境的无界面静默 DDNS 工具。能够自动绕过系统代理（如 Clash/v2ray 等），直接获取硬路由器拨号的真实公网 IPv4，并同步更新至 Cloudflare DNS 解析。

## 项目特性

* **强制直连**：彻底绕过系统代理，获取真实的拨号公网 IP。
* **多源校验**：集成多个外网 IP 接口，自动判定与容错降级。
* **本地缓存**：内置 `last_ip.txt` 缓存，仅在 IP 变动时调用 Cloudflare API。
* **极简部署**：基于纯正 PowerShell 5.1 编写，无须安装额外依赖。

## 目录结构

所有核心文件统一放置在 Windows 的 `C:\ProgramData\CloudflareDDNS\` 目录下：

```text
C:\ProgramData\CloudflareDDNS\
├── config.json           # API 密钥与域名配置文件
├── cloudflare-ddns.ps1   # 核心执行脚本
├── last_ip.txt           # 本地 IP 缓存文件（脚本自动生成）
├── ddns.log              # 运行日志（脚本自动生成）
└── README.md             # 使用说明文档
```

## 使用说明

### 1. 准备目录与配置

在本地创建文件夹：

```text
C:\ProgramData\CloudflareDDNS\
```

并新建 `config.json` 文件：

```json
{
  "ApiToken": "你的Cloudflare_API_Token",
  "ZoneId": "你的Zone_ID",
  "RecordName": "你的Domain_name"
}
```

### 2. 保存脚本文件

将本仓库中的 `cloudflare-ddns.ps1` 下载并保存至：

```text
C:\ProgramData\CloudflareDDNS\cloudflare-ddns.ps1
```

### 3. 配置 Windows 计划任务

以管理员身份打开 PowerShell，复制运行以下命令（系统级计划任务，每10分钟运行一次）：

```powershell
schtasks --% /Create /TN "CloudflareDDNS" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\ProgramData\CloudflareDDNS\cloudflare-ddns.ps1" /SC MINUTE /MO 10 /RU "NT AUTHORITY\SYSTEM" /RL HIGHEST /F
```

### 4. 验证运行状态

可打开以下日志文件查看后台运行日志：

```text
C:\ProgramData\CloudflareDDNS\ddns.log
```
