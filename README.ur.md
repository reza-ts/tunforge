# Tunforge

[English](README.md) · [فارسی](README.fa.md) · [中文](README.zh.md) · [Русский](README.ru.md) · [اردو](README.ur.md) · [Türkmen](README.tk.md)

---

<div dir="rtl">

**Tunforge** Ubuntu 22.04 کے لیے ایک واحد ماخذ (single source of truth) VPN کنٹرول پلین ہے۔ یہ چار باہم متضاد کنکشن پروفائل اقسام کو منظم کرتا ہے اور DNS، IP اور IPv6 لیکس کو روکتا ہے — پروفائل تبدیل کرنے پر بھی۔

- **Direct** — VPN نہیں؛ راؤٹر سے DNS
- **WireGuard** — `wg-quick` پر مبنی، کثیر سرور
- **OpenVPN** — `.ovpn` کنفیگز، کثیر سرور
- **sing-box TUN** — VMess / VLESS / Trojan / Shadowsocks کے لیے سسٹم وائڈ ٹنل

بنیادی انٹرفیس `whiptail` TUI ہے۔ عملیات `flock` کے تحت ترتیب وار ہیں؛ اگلی پروفائل سے پہلے پچھلی مکمل طور پر بند ہوتی ہے؛ DNS `systemd-resolved` per-link روٹنگ سے ٹنل پر لاک ہوتا ہے؛ `nftables` kill switch لگایا جاتا ہے؛ اور غیر-direct پروفائل فعال ہونے پر IPv6 سسٹم وائڈ بند ہوتا ہے۔

**حیثیت:** Ubuntu 22.04 (amd64 / arm64) پر آزمائی اور کام کر رہا ہے۔

### معماری

Tunforge ایک چھوٹا کنٹرول پلین ہے: ایک CLI/TUI عملیہ عالمی لاک کے تحت connect/disconnect سنبھالتا ہے، ٹنل bring-up کنیکٹر کو سونپتا ہے، پھر میزبان کو سخت بناتا ہے (DNS، nftables، IPv6) اور کامیابی سے پہلے تصدیق کرتا ہے۔

**کنکشن کا راستہ (کامیاب):**

1. `/var/lib/tunforge/lock` پر `flock` حاصل کریں
2. پچھلی پروفائل مکمل بند کریں
3. منتخب کنیکٹر چلائیں (WireGuard / OpenVPN / sing-box / direct)
4. DNS ٹنل iface پر لاک (`resolvectl` + `~.` domain)
5. nftables kill switch (`inet tunforge`)
6. IPv6 بند (غیر-direct) اور LAN discovery خاموش
7. `verify.sh` چلائیں؛ ناکامی پر خودکار direct پر واپسی

**ڈیزائن اصول:**

| اصول | طریقہ |
|---|---|
| واحد ماخذ | `/var/lib/tunforge/active` ایٹمک اپڈیٹ؛ ایک وقت میں ایک پروفائل |
| ترتیب وار تبدیلیاں | تمام connect/disconnect ایک ہی flock |
| fail closed | kill switch + verify rollback |
| قابل تبدیل ٹنلز | کنیکٹرز پتلا معاہدہ؛ کور پالیسی کا مالک |

ریپو کی ساخت runtime کو `/usr/local` اور `/etc/tunforge` میں عکس کرتی ہے ([لے آؤٹ](#layout))۔

### انسٹال (Ubuntu 22.04)

```bash
git clone <this-repo> tunforge
cd tunforge
sudo ./install.sh
```

انسٹالر:

1. Preflight: Ubuntu 22.04 / `--force`، root، arch، `systemd-resolved`
2. Apt: صرف غائب پیکجز
3. sing-box: GitHub Releases سے `.deb`، SHA256، `dpkg -i`
4. `/usr/local/bin/`، `/usr/local/lib/tunforge/`، `/etc/tunforge/`
5. NetworkManager اور resolved drop-ins
6. `tunforge-killswitch.service` فعال

```bash
sudo ./install.sh --check
sudo ./install.sh --no-singbox
sudo ./install.sh --singbox-deb ./sing-box_1.10.3_linux_amd64.deb
```

### ان انسٹال

```bash
sudo ./uninstall.sh
sudo ./uninstall.sh --purge
```

### فوری آغاز

1. کنفیگ فائلیں رکھیں:

   - WireGuard: `/etc/tunforge/configs/wireguard/de1.conf` (chmod 600)
   - OpenVPN: `/etc/tunforge/configs/openvpn/nl1.ovpn`
   - sing-box: `/etc/tunforge/configs/singbox/jp1.json`

   V2Ray URI (`vmess://`، `vless://`، `trojan://`، `ss://`) کے لیے:

   ```bash
   sudo tunforge import 'vless://uuid@server:443?security=tls&type=ws&path=/api#JP-Tokyo'
   ```

2. `/etc/tunforge/profiles/<name>.profile` بنائیں:

   ```bash
   sudo tunforge scaffold
   ```

3. چلائیں:

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

### V2Ray URI درآمد

```bash
sudo tunforge import 'vless://...#JP-Tokyo'
sudo tunforge import 'vmess://eyJ2I...' jp-tokyo
echo "$URI" | sudo tunforge import -
sudo tunforge import -f ~/subs.txt
```

### V2Ray سبسکرپشن (soft sub)

```bash
sudo tunforge subscription add https://provider.example/sub?token=abc myprovider
sudo tunforge subscription update myprovider
sudo tunforge subscription update all
sudo tunforge subscription list
sudo tunforge subscription remove myprovider
```

### پروفائل فائل

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

### لیک تحفظ کیسے کام کرتا ہے

| پرت | طریقہ |
|---|---|
| DNS | `resolvectl` per-link لاک |
| روٹس | ٹنل کے ذریعے ڈیفالٹ روٹ |
| Kill switch | `inet tunforge`، `output policy drop` |
| IPv6 | VPN پر sysctl بند |
| بوٹ | `tunforge-killswitch.service` NetworkManager سے پہلے |
| تصدیق | `verify.sh`؛ ناکامی → direct |

#### مقامی ترقی bypass

پہلے سے: `127.0.0.0/8`، `10.0.0.0/8`، `172.16.0.0/12`، `192.168.0.0/16`، `169.254.0.0/16`۔

```bash
sudo tunforge bypass add-cidr 172.17.0.0/16
sudo tunforge bypass add-domain backend.local
tunforge bypass list
```

#### Google DNS کیوں ممنوع

`8.8.8.8` اور `8.8.4.4` Gmail / Workspace / Firebase کے ساتھ ایک وینڈر کے ہیں۔ Cloudflare (`1.1.1.1`)، Quad9 (`9.9.9.9`) ترجیح دیں۔

### جو حل نہیں ہوتا (براؤزر پرت)

- **WebRTC** — STUN سے اصل IP
- **براؤزر فنگر پرنٹنگ**
- **لاگ ان اکاؤنٹ correlation**
- **HTTP/3 (QUIC)**

### لے آؤٹ


انگریزی ورژن جیسا: `/usr/local/bin/`، `/usr/local/lib/tunforge/`، `/etc/tunforge/`، `/var/lib/tunforge/`۔

### تعاون

خوش آمدید — بگ فکس، لیک سختگی، نیا کنیکٹر، دستاویزات۔

1. Fork اور شاخ (`feat/…`، `fix/…`، `docs/…`)
2. ایک PR میں ایک موضوع
3. Ubuntu 22.04 پر ٹیسٹ
4. PR میں مسئلہ، طریقہ اور تصدیق

### ٹربل شوٹنگ

```bash
sudo tunforge doctor
sudo tunforge logs
sudo tunforge disconnect
sudo nft list table inet tunforge
resolvectl status
ip -4 route get 1.1.1.1
```

`verify.sh` rollback کی وجہ: `journalctl -t tunforge -n 50`۔

</div>
