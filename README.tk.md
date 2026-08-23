# Tunforge

[English](README.md) · [فارسی](README.fa.md) · [中文](README.zh.md) · [Русский](README.ru.md) · [اردو](README.ur.md) · [Türkmen](README.tk.md)

---

**Tunforge** Ubuntu 22.04 üçin ýeke çeşmeli VPN dolandyryş meýdançasy. Dört özara çaknyşmaýan birikme profilini dolandyrýar we DNS, IP we IPv6 syzmalarynyň öňüni alýar — profil çalşylanda hem.

- **Direct** — VPN ýok; router DNS
- **WireGuard** — `wg-quick` esasynda, köp serwer
- **OpenVPN** — `.ovpn` konfigurasiýalar, köp serwer
- **sing-box TUN** — VMess / VLESS / Trojan / Shadowsocks üçin ulgam derejesindäki tunel

Esasy interfeýs `whiptail` TUI. Amallar `flock` astynda yzygiderli; indiki profil ýokarlanmazdan öňki doly ýygylyar; DNS `systemd-resolved` per-link marşrutlamasy bilen tunel bilen gulplanýar; `nftables` kill switch gurnalýar; direct däl profil işjeň wagtynda IPv6 ulgam boýunça öçürilýär.

**Ýagdaýy:** Ubuntu 22.04 (amd64 / arm64) üstünde synagdan geçirildi we işleýär.

### Arhitektura

Tunforge kiçi dolandyryş meýdançasy: bir CLI/TUI prosesi global gulp astynda connect/disconnect dolandyrýar, tunel ýokarlamagy konnektora tabşyrýar, soňra hosty berkidýär (DNS, nftables, IPv6) we üstünlik diýmezden öň barlaýar.

**Birikmek ýoly (üstünlikli):**

1. `/var/lib/tunforge/lock` üstünde `flock` almak
2. Öňki profili doly ýygyrmak
3. Saýlanan konnektory ýokarlamak (WireGuard / OpenVPN / sing-box / direct)
4. DNS-i tunel iface-a gulplamak (`resolvectl` + `~.` domeni)
5. nftables kill switch gurnamak (`inet tunforge`)
6. IPv6 öçürmek (direct däl) we LAN açyş sesini duruzmak
7. `verify.sh` işletmek; şowsuzlykda awtomatik direct-e yzyna gaýtmak

**Dizaýn ýörelgeleri:**

| Ýörelge | Nähili |
|---|---|
| Ýeke çeşme | `/var/lib/tunforge/active` atomik täzelenýär; bir wagtda bir profil |
| Yzygiderli üýtgeşmeler | Connect/disconnect ýollary bir flock |
| Fail closed | Kill switch + verify yzyna gaýdyryş |
| Goşulýan tuneller | Konnektorlar ýňňe şertnama; özeg syýasaty eýeleýär |

Repozitoriý gurluşy `/usr/local` we `/etc/tunforge` astyndaky runtime-y aýnadýar ([Gurluş](#layout)).

### Gurnamak (Ubuntu 22.04)

```bash
git clone <this-repo> tunforge
cd tunforge
sudo ./install.sh
```

Gurnawçy:

1. Preflight: Ubuntu 22.04 / `--force`, root, arch, `systemd-resolved`
2. Apt: diňe ýok paketler
3. sing-box: GitHub Releases-den `.deb`, SHA256, `dpkg -i`
4. `/usr/local/bin/`, `/usr/local/lib/tunforge/`, `/etc/tunforge/`
5. NetworkManager we resolved drop-inler
6. `tunforge-killswitch.service` işjeňleşdirilýär

```bash
sudo ./install.sh --check
sudo ./install.sh --no-singbox
sudo ./install.sh --singbox-deb ./sing-box_1.10.3_linux_amd64.deb
```

### Aýyrmak

```bash
sudo ./uninstall.sh
sudo ./uninstall.sh --purge
```

### Çalt başlamak

1. Konfigurasiýa faýllaryny goýuň:

   - WireGuard: `/etc/tunforge/configs/wireguard/de1.conf` (chmod 600)
   - OpenVPN: `/etc/tunforge/configs/openvpn/nl1.ovpn`
   - sing-box: `/etc/tunforge/configs/singbox/jp1.json`

   V2Ray URI (`vmess://`, `vless://`, `trojan://`, `ss://`) üçin:

   ```bash
   sudo tunforge import 'vless://uuid@server:443?security=tls&type=ws&path=/api#JP-Tokyo'
   ```

2. `/etc/tunforge/profiles/<name>.profile` dörediň:

   ```bash
   sudo tunforge scaffold
   ```

3. Işlediň:

   ```bash
   sudo tunforge
   ```

CLI:

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

### V2Ray URI import

```bash
sudo tunforge import 'vless://...#JP-Tokyo'
sudo tunforge import 'vmess://eyJ2I...' jp-tokyo
echo "$URI" | sudo tunforge import -
sudo tunforge import -f ~/subs.txt
```

### V2Ray abunalyk (soft sub)

```bash
sudo tunforge subscription add https://provider.example/sub?token=abc myprovider
sudo tunforge subscription update myprovider
sudo tunforge subscription update all
sudo tunforge subscription list
sudo tunforge subscription remove myprovider
```

### Profil faýly

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

### Syzma goragynyň işleýşi

| Gat | Mechanizm |
|---|---|
| DNS | `resolvectl` per-link gulp |
| Marşrutlar | Tunel arkaly default route |
| Kill switch | `inet tunforge`, `output policy drop` |
| IPv6 | VPN wagtynda sysctl öçürme |
| Ýükleme | `tunforge-killswitch.service` NetworkManager-den öň |
| Barlag | `verify.sh`; şowsuzlyk → direct |

#### Ýerli ösüş bypass

Deslapdan: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`.

```bash
sudo tunforge bypass add-cidr 172.17.0.0/16
sudo tunforge bypass add-domain backend.local
tunforge bypass list
```

#### Näme üçin Google DNS gadagan

`8.8.8.8` we `8.8.4.4` Gmail / Workspace / Firebase bilen bir vendor. Cloudflare (`1.1.1.1`), Quad9 (`9.9.9.9`) ulanyň.

### Çözülmeýän zatlar (brauzer gatlagy)

- **WebRTC** — STUN arkaly hakyky IP
- **Brauzer barmak yzy**
- **Hasap baglanyşygy**
- **HTTP/3 (QUIC)**

### Gurluş


Iňlis wersiýasy ýaly: `/usr/local/bin/`, `/usr/local/lib/tunforge/`, `/etc/tunforge/`, `/var/lib/tunforge/`.

### Goşant

Hoş geldiňiz — bug düzetmek, syzma ýollaryny berkitmek, täze konnektor, resminamalar.

1. Fork we şahamça (`feat/…`, `fix/…`, `docs/…`)
2. Bir PR-da bir mesele
3. Ubuntu 22.04-da synag
4. Mesele, çemeleşme we barlag bilen PR

### Mesele çözmek

```bash
sudo tunforge doctor
sudo tunforge logs
sudo tunforge disconnect
sudo nft list table inet tunforge
resolvectl status
ip -4 route get 1.1.1.1
```

`verify.sh` yzyna gaýdyryş sebäbi: `journalctl -t tunforge -n 50`.
