# Tunforge

[English](README.md) · [فارسی](README.fa.md) · [中文](README.zh.md) · [Русский](README.ru.md) · [اردو](README.ur.md) · [Türkmen](README.tk.md)

---

**Tunforge** 是面向 Ubuntu 22.04 的单一可信源 VPN 控制平面。它管理四种互斥的连接配置类型，并防止 DNS、IP 和 IPv6 泄漏——包括在切换配置时。

- **Direct** — 无 VPN；使用路由器提供的 DNS
- **WireGuard** — 基于 `wg-quick`，支持多服务器
- **OpenVPN** — `.ovpn` 配置，支持多服务器
- **sing-box TUN** — 系统级隧道，支持 VMess / VLESS / Trojan / Shadowsocks

主界面为 `whiptail` TUI。操作在 `flock` 下串行化；下一个配置启动前会完全拆除上一个；DNS 通过 `systemd-resolved` 按链路路由锁定到隧道；安装 `nftables` 终止开关；非 direct 配置激活时系统级禁用 IPv6。

**状态：** 已在 Ubuntu 22.04（amd64 / arm64）上测试通过。

### 架构

Tunforge 是一个轻量控制平面：单个 CLI/TUI 进程在全局锁下负责连接/断开，将隧道启动委托给连接器，然后加固主机（DNS、nftables、IPv6）并在宣告成功前进行验证。

**连接路径（正常流程）：**

1. 在 `/var/lib/tunforge/lock` 上获取 `flock`
2. 完全拆除上一配置（连接器下线 + DNS 恢复 + 清除防火墙 + 按需恢复 IPv6）
3. 启动所选连接器（WireGuard / OpenVPN / sing-box / direct）
4. 将 DNS 锁定到隧道接口（`resolvectl` + 仅路由域 `~.`）
5. 安装 nftables 终止开关（`inet tunforge`，默认丢弃出站）
6. 禁用 IPv6（非 direct）并停止 LAN 发现噪声
7. 运行 `verify.sh`；失败则自动回滚到 direct

**设计原则：**

| 原则 | 实现方式 |
|---|---|
| 单一可信源 | `/var/lib/tunforge/active` 原子更新；同时仅一个配置 |
| 串行变更 | 所有连接/断开路径使用同一 flock |
| 失败即关闭 | 终止开关 + 验证回滚；启动单元在 NetworkManager 之前重新应用防火墙 |
| 可插拔隧道 | 连接器共享薄契约；核心拥有策略，而非协议细节 |

仓库布局镜像 `/usr/local` 和 `/etc/tunforge` 下的运行时布局（见[目录结构](#layout)）。

### 安装（Ubuntu 22.04）

```bash
git clone <this-repo> tunforge
cd tunforge
sudo ./install.sh
```

安装程序执行：

1. 预检：Ubuntu 22.04 / 其他版本用 `--force`，root，架构（amd64 / arm64），`systemd-resolved` 存在。
2. Apt：仅安装缺失包 — `wireguard-tools openvpn nftables whiptail iproute2 curl jq gawk dnsutils ca-certificates moreutils`。
3. sing-box：从 GitHub Releases 获取最新 `.deb`，如有 `.sha256` 则校验，然后 `dpkg -i`。用 `--no-singbox` 跳过，或用 `--singbox-deb /path/to/file.deb` 提供离线包。
4. 部署二进制到 `/usr/local/bin/`，库到 `/usr/local/lib/tunforge/`，配置到 `/etc/tunforge/`。
5. 安装 `NetworkManager` 和 `systemd-resolved` drop-in，避免 DNS/VPN 接口冲突，并将 `/etc/resolv.conf` 指向 systemd stub（含备份）。
6. 启用 `tunforge-killswitch.service`，防止 VPN 中途重启泄漏。

可重复运行（幂等）。`--check` 为试运行。

```bash
sudo ./install.sh --check
sudo ./install.sh --no-singbox
sudo ./install.sh --singbox-deb ./sing-box_1.10.3_linux_amd64.deb
```

### 卸载

```bash
sudo ./uninstall.sh           # 移除 Tunforge，保留配置和 profile
sudo ./uninstall.sh --purge   # 同时清除 /etc/tunforge 和 /var/lib/tunforge
```

Apt 包保留（可能被他处使用）。结束时打印移除提示。

### 快速开始

1. 放置配置文件：

   - WireGuard: `/etc/tunforge/configs/wireguard/de1.conf`（chmod 600 — 含私钥）
   - OpenVPN: `/etc/tunforge/configs/openvpn/nl1.ovpn`
   - sing-box: `/etc/tunforge/configs/singbox/jp1.json`

   对于 V2Ray 风格 URI（`vmess://`、`vless://`、`trojan://`、`ss://`）可跳过步骤 1，使用导入器：

   ```bash
   sudo tunforge import 'vless://uuid@server:443?security=tls&type=ws&path=/api#JP-Tokyo'
   ```

2. 在 `/etc/tunforge/profiles/<name>.profile` 创建 profile 描述符：

   ```bash
   sudo tunforge scaffold
   ```

   或使用 TUI：**Manage profiles → Scaffold from existing configs**。已有 profile 不会被覆盖。

3. 启动：

   ```bash
   sudo tunforge
   ```

   - **Connect** — 切换配置（`*` 标记当前）
   - **Disconnect** — 返回 direct 模式
   - **Status** — 当前配置、接口、DNS、隧道公网 IP
   - **Live logs** — 彩色 journald 跟踪
   - **Doctor** — 健康检查 + 终止开关规则转储

CLI 可用于脚本：

```bash
sudo tunforge list
sudo tunforge connect wg-de1
sudo tunforge status
sudo tunforge doctor
sudo tunforge disconnect
sudo tunforge import '<uri>'
sudo tunforge bypass add backend.local
sudo tunforge bypass add-cidr 172.17.0.0/16
tunforge logs
```

### V2Ray URI 导入

```bash
sudo tunforge import 'vless://...#JP-Tokyo'
sudo tunforge import 'vmess://eyJ2I...' jp-tokyo
echo "$URI" | sudo tunforge import -
sudo tunforge import -f ~/subs.txt
```

支持的方案：`vmess://`、`vless://`、`trojan://`、`ss://`（详见英文版表格）。

导入后可在 `/etc/tunforge/profiles/<name>.profile` 调整 DNS，然后：

```bash
sudo tunforge connect <name>
```

### V2Ray 订阅（soft sub）

*订阅*是返回 V2Ray URI **列表**的远程 URL。存储 URL 后**刷新**即可获取提供商当前服务器列表。

```bash
sudo tunforge subscription add https://provider.example/sub?token=abc myprovider
sudo tunforge subscription update myprovider
sudo tunforge subscription update all
sudo tunforge subscription list
sudo tunforge subscription remove myprovider
```

### Profile 文件

```bash
TYPE=wireguard
DESC="Germany #1"
COUNTRY=Germany
CONFIG=/etc/tunforge/configs/wireguard/de1.conf
DNS_SERVERS="1.1.1.1 9.9.9.9"
DNS_OVER_TLS=opportunistic
KILL_SWITCH=yes
IPV6=disable
ENDPOINT_IP=203.0.113.45
MTU=1280
```

### 防泄漏机制

| 层 | 机制 |
|---|---|
| DNS | `resolvectl` per-link 锁定；VPN 接口为唯一解析器 |
| 路由 | 默认路由经隧道 |
| 终止开关 | `inet tunforge` 表，`output policy drop` |
| IPv6 | 非 direct 时 sysctl 禁用 |
| 启动 | `tunforge-killswitch.service` 在 NetworkManager 之前 |
| 连接后验证 | `verify.sh`；失败自动回滚到 direct |

#### 本地开发绕过

默认绕过：`127.0.0.0/8`、`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、`169.254.0.0/16`。

```bash
sudo tunforge bypass add-cidr 172.17.0.0/16
sudo tunforge bypass add-domain backend.local
tunforge bypass list
```

#### 为何禁止 Google DNS

`8.8.8.8` 和 `8.8.4.4` 与 Gmail / Workspace / Firebase 同属一家。profile 加载器会硬拒绝。请使用 Cloudflare（`1.1.1.1`）、Quad9（`9.9.9.9`）等。

### 无法解决的问题（浏览器层）

- **WebRTC** — 浏览器可通过 STUN 探测真实 IP
- **浏览器指纹** — canvas、字体、时区
- **登录账户关联** — 为每个出口使用独立浏览器配置
- **HTTP/3 (QUIC)** — 终止开关开启时 UDP/443 非隧道流量会被丢弃

### 目录结构


与英文版相同：`/usr/local/bin/`、`/usr/local/lib/tunforge/`、`/etc/tunforge/`、`/var/lib/tunforge/`。

### 贡献

欢迎贡献 — 修复 Ubuntu 22.04 上的 bug、加固泄漏路径、添加连接器或改进文档。

1. Fork 并创建专注分支（`feat/…`、`fix/…`、`docs/…`）
2. 保持变更范围小；每个 PR 一个主题
3. 涉及网络/DNS/防火墙时在 Ubuntu 22.04 上测试
4. 提交说明问题、方案和验证方式的 PR

### 故障排除

```bash
sudo tunforge doctor
sudo tunforge logs
sudo tunforge disconnect
sudo nft list table inet tunforge
resolvectl status
ip -4 route get 1.1.1.1
```

若 `verify.sh` 已回滚，原因见 `journalctl -t tunforge -n 50`。
