# Tunforge

[English](README.md) · [فارسی](README.fa.md) · [中文](README.zh.md) · [Русский](README.ru.md) · [اردو](README.ur.md) · [Türkmen](README.tk.md)

---

<div dir="rtl">

**Tunforge** یک صفحهٔ کنترل VPN با منبع واحد حقیقت برای Ubuntu 22.04 است. چهار نوع پروفایل اتصالِ غیرهم‌زمان را مدیریت می‌کند و از نشت DNS، IP و IPv6 — حتی هنگام تعویض پروفایل — جلوگیری می‌کند.

- **Direct** — بدون VPN؛ DNS از روتر
- **WireGuard** — مبتنی بر `wg-quick`، چند سرور
- **OpenVPN** — پیکربندی `.ovpn`، چند سرور
- **sing-box TUN** — تونل سراسری سیستم برای VMess / VLESS / Trojan / Shadowsocks

رابط اصلی، TUI مبتنی بر `whiptail` است. عملیات تحت `flock` سریال‌سازی می‌شوند؛ پروفایل قبلی پیش از بالا آمدن پروفایل بعدی کاملاً جمع می‌شود؛ DNS از طریق مسیریابی per-link در `systemd-resolved` به تونل قفل می‌شود؛ kill switch مبتنی بر `nftables` نصب می‌شود؛ و IPv6 در سراسر سیستم هنگام فعال بودن پروفایل غیرمستقیم غیرفعال می‌شود.

**وضعیت:** روی Ubuntu 22.04 (amd64 / arm64) آزمایش و تأیید شده است.

### معماری

Tunforge یک صفحهٔ کنترل کوچک است: یک فرایند CLI/TUI اتصال/قطع را تحت قفل سراسری مدیریت می‌کند، بالا آوردن تونل را به connector واگذار می‌کند، سپس میزبان را سخت‌سازی می‌کند (DNS، nftables، IPv6) و پیش از اعلام موفقیت تأیید می‌کند.

**مسیر اتصال (مسیر موفق):**

1. دریافت `flock` روی `/var/lib/tunforge/lock`
2. جمع‌کردن کامل پروفایل قبلی (قطع connector + بازگردانی DNS + پاک‌سازی فایروال + بازگردانی IPv6 در صورت نیاز)
3. بالا آوردن connector انتخاب‌شده (WireGuard / OpenVPN / sing-box / direct)
4. قفل DNS روی رابط تونل (`resolvectl` + دامنهٔ مسیریابی‌فقط `~.`)
5. نصب kill switch مبتنی بر nftables (`inet tunforge`، پیش‌فرض drop خروجی)
6. غیرفعال‌سازی IPv6 (غیرمستقیم) و توقف نویز کشف LAN
7. اجرای `verify.sh`؛ در صورت شکست، بازگشت خودکار به direct

**اصول طراحی:**

| اصل | نحوهٔ پیاده‌سازی |
|---|---|
| منبع واحد حقیقت | `/var/lib/tunforge/active` به‌صورت اتمی به‌روز می‌شود؛ فقط یک پروفایل در هر زمان |
| تغییرات سریال‌شده | همهٔ مسیرهای connect/disconnect همان flock را می‌گیرند |
| شکست بسته | kill switch + بازگشت verify؛ واحد بوت فایروال را پیش از NetworkManager اعمال می‌کند |
| تونل‌های قابل جایگزینی | connectorها قرارداد نازکی دارند؛ هسته سیاست را مالک است، نه جزئیات پروتکل |

چیدمان مخزن، چیدمان زمان اجرا زیر `/usr/local` و `/etc/tunforge` را منعکس می‌کند (بخش [چیدمان](#layout)).

### نصب (Ubuntu 22.04)

```bash
git clone <this-repo> tunforge
cd tunforge
sudo ./install.sh
```

نصب‌کننده چه می‌کند:

1. پیش‌بررسی: Ubuntu 22.04 / `--force` برای سایر نسخه‌ها، root، معماری (amd64 / arm64)، وجود `systemd-resolved`.
2. Apt: فقط بسته‌های نبوده را نصب می‌کند — `wireguard-tools openvpn nftables whiptail iproute2 curl jq gawk dnsutils ca-certificates moreutils`.
3. sing-box: آخرین `.deb` را از GitHub Releases برای معماری شما می‌گیرد، در صورت وجود فایل `.sha256` هش را تأیید می‌کند، سپس `dpkg -i`. با `--no-singbox` رد کنید یا `.deb` آفلاین با `--singbox-deb /path/to/file.deb` بدهید.
4. باینری‌ها را در `/usr/local/bin/`، کتابخانه‌ها در `/usr/local/lib/tunforge/` و پیکربندی‌ها در `/etc/tunforge/` مستقر می‌کند.
5. drop-inهای `NetworkManager` و `systemd-resolved` نصب می‌کند تا روی DNS / رابط VPN درگیر نشوند، و `/etc/resolv.conf` را به stub systemd اشاره می‌دهد (با پشتیبان).
6. `tunforge-killswitch.service` را فعال می‌کند تا ری‌استارت وسط VPN نشت نکند.

اجرای مجدد ایمن است (idempotent). برای آزمایش خشک `--check` بدهید.

```bash
sudo ./install.sh --check
sudo ./install.sh --no-singbox
sudo ./install.sh --singbox-deb ./sing-box_1.10.3_linux_amd64.deb
```

### حذف نصب

```bash
sudo ./uninstall.sh           # Tunforge را حذف می‌کند اما پروفایل‌ها و پیکربندی‌ها را نگه می‌دارد
sudo ./uninstall.sh --purge   # همچنین /etc/tunforge و /var/lib/tunforge را پاک می‌کند
```

بسته‌های Apt باقی می‌مانند (ممکن است جای دیگر استفاده شوند). در پایان راهنمای حذف چاپ می‌شود.

### شروع سریع

1. فایل‌های پیکربندی را قرار دهید:

   - WireGuard: `/etc/tunforge/configs/wireguard/de1.conf` (chmod 600 — شامل کلید خصوصی)
   - OpenVPN: `/etc/tunforge/configs/openvpn/nl1.ovpn`
   - sing-box: `/etc/tunforge/configs/singbox/jp1.json`

   برای URIهای سبک V2Ray (`vmess://`، `vless://`، `trojan://`، `ss://`) مرحلهٔ ۱ را رد کنید و از importer استفاده کنید:

   ```bash
   sudo tunforge import 'vless://uuid@server:443?security=tls&type=ws&path=/api#JP-Tokyo'
   ```

2. یک توصیف‌گر پروفایل در `/etc/tunforge/profiles/<name>.profile` بسازید:

   ```bash
   sudo tunforge scaffold
   ```

   یا از TUI: **Manage profiles → Scaffold from existing configs**. پروفایل‌های موجود هرگز بازنویسی نمی‌شوند.

3. اجرا:

   ```bash
   sudo tunforge
   ```

   - **Connect** — تعویض پروفایل
   - **Disconnect** — بازگشت به حالت مستقیم
   - **Status** — پروفایل فعال، رابط، DNS، IP عمومی از تونل
   - **Live logs** — دنبالهٔ رنگی journald
   - **Doctor** — بررسی سلامت + dump قوانین kill switch

CLI برای اسکریپت‌نویسی:

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

### وارد کردن URI مربوط به V2Ray

```bash
sudo tunforge import 'vless://...#JP-Tokyo'
sudo tunforge import 'vmess://eyJ2I...' jp-tokyo
echo "$URI" | sudo tunforge import -
sudo tunforge import -f ~/subs.txt
```

پس از import، در صورت نیاز DNS را در `/etc/tunforge/profiles/<name>.profile` ویرایش کنید، سپس:

```bash
sudo tunforge connect <name>
```

### اشتراک V2Ray (soft sub)

یک *اشتراک* URL راه‌دور است که **فهرستی** از URIهای V2Ray برمی‌گرداند. URL را یک‌بار ذخیره کنید و **به‌روزرسانی** کنید تا فهرست فعلی ارائه‌دهنده بیاید.

```bash
sudo tunforge subscription add https://provider.example/sub?token=abc myprovider
sudo tunforge subscription update myprovider
sudo tunforge subscription update all
sudo tunforge subscription list
sudo tunforge subscription remove myprovider
```

### فایل پروفایل

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

### نحوهٔ محافظت در برابر نشت

| لایه | مکانیزم |
|---|---|
| DNS | قفل per-link با `resolvectl`؛ فقط رابط VPN resolver است |
| مسیرها | مسیر پیش‌فرض از تونل |
| Kill switch | جدول `inet tunforge` با `output policy drop` |
| IPv6 | غیرفعال‌سازی sysctl هنگام VPN |
| بوت | `tunforge-killswitch.service` پیش از NetworkManager |
| تأیید پس از اتصال | `verify.sh`؛ شکست → بازگشت خودکار به direct |

#### دور زدن شبکهٔ توسعهٔ محلی

شبکه‌های توسعهٔ محلی به‌طور پیش‌فرض از VPN عبور می‌کنند: `127.0.0.0/8`، `10.0.0.0/8`، `172.16.0.0/12`، `192.168.0.0/16`، `169.254.0.0/16`.

```bash
sudo tunforge bypass add-cidr 172.17.0.0/16
sudo tunforge bypass add-domain backend.local
tunforge bypass list
```

#### چرا Google DNS ممنوع است

`8.8.8.8` و `8.8.4.4` متعلق به همان شرکت Gmail / Workspace / Firebase هستند. بارگذار پروفایل آن‌ها را رد می‌کند. از Cloudflare (`1.1.1.1`)، Quad9 (`9.9.9.9`) یا resolver دیگری استفاده کنید.

### آنچه حل نمی‌شود (لایهٔ مرورگر)

- **WebRTC** — مرورگرها می‌توانند IP واقعی را از STUN بگیرند
- **اثر انگشت مرورگر** — canvas، فونت، منطقهٔ زمانی
- **همبستگی حساب واردشده** — از پروفایل مرورگر جدا برای هر خروجی استفاده کنید
- **HTTP/3 (QUIC)** — با kill switch فعال، UDP/443 خارج تونل drop می‌شود

### چیدمان


همان ساختار انگلیسی: باینری‌ها در `/usr/local/bin/`، کتابخانه‌ها در `/usr/local/lib/tunforge/`، پیکربندی در `/etc/tunforge/`، وضعیت در `/var/lib/tunforge/`.

### مشارکت

مشارکت‌ها خوش‌آمد است — رفع باگ، سخت‌سازی مسیرهای نشت، افزودن connector، یا بهبود مستندات.

1. Fork کنید و شاخهٔ متمرکز بسازید (`feat/…`، `fix/…`، `docs/…`)
2. تغییرات را محدود نگه دارید؛ یک موضوع در هر PR
3. روی Ubuntu 22.04 آزمایش کنید
4. PR با توضیح مشکل، رویکرد و نحوهٔ تأیید باز کنید

### عیب‌یابی

```bash
sudo tunforge doctor
sudo tunforge logs
sudo tunforge disconnect
sudo nft list table inet tunforge
resolvectl status
ip -4 route get 1.1.1.1
```

دلیل بازگشت `verify.sh` در `journalctl -t tunforge -n 50` است.

</div>
