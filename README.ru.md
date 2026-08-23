# Tunforge

[English](README.md) · [فارسی](README.fa.md) · [中文](README.zh.md) · [Русский](README.ru.md) · [اردو](README.ur.md) · [Türkmen](README.tk.md)

---

**Tunforge** — единый VPN control plane для Ubuntu 22.04. Управляет четырьмя взаимоисключающими типами профилей подключения и предотвращает утечки DNS, IP и IPv6 — в том числе при переключении профилей.

- **Direct** — без VPN; DNS от роутера
- **WireGuard** — на базе `wg-quick`, несколько серверов
- **OpenVPN** — конфиги `.ovpn`, несколько серверов
- **sing-box TUN** — системный туннель для VMess / VLESS / Trojan / Shadowsocks

Основной интерфейс — TUI на `whiptail`. Операции сериализуются через `flock`; предыдущий профиль полностью снимается перед поднятием следующего; DNS блокируется на туннеле через per-link маршрутизацию `systemd-resolved`; устанавливается kill switch на `nftables`; IPv6 отключается системно при активном не-direct профиле.

**Статус:** протестировано на Ubuntu 22.04 (amd64 / arm64).

### Архитектура

Tunforge — небольшой control plane: один процесс CLI/TUI под глобальной блокировкой управляет connect/disconnect, делегирует поднятие туннеля коннектору, затем усиливает хост (DNS, nftables, IPv6) и проверяет перед объявлением успеха.

**Путь подключения (успешный сценарий):**

1. Захват `flock` на `/var/lib/tunforge/lock`
2. Полное снятие предыдущего профиля (коннектор down + откат DNS + очистка firewall + восстановление IPv6 при необходимости)
3. Поднятие выбранного коннектора (WireGuard / OpenVPN / sing-box / direct)
4. Блокировка DNS на интерфейсе туннеля (`resolvectl` + route-only домен `~.`)
5. Установка kill switch nftables (`inet tunforge`, output drop по умолчанию)
6. Отключение IPv6 (не-direct) и остановка шума LAN discovery
7. Запуск `verify.sh`; при сбое — автоматический откат к direct

**Принципы проектирования:**

| Принцип | Реализация |
|---|---|
| Единый источник истины | `/var/lib/tunforge/active` обновляется атомарно; один профиль за раз |
| Сериализованные изменения | Все пути connect/disconnect используют один flock |
| Fail closed | Kill switch + откат verify; boot unit применяет firewall до NetworkManager |
| Подключаемые туннели | Коннекторы с тонким контрактом; ядро владеет политикой, не деталями протокола |

Структура репозитория отражает runtime под `/usr/local` и `/etc/tunforge` (см. [Структура](#layout)).

### Установка (Ubuntu 22.04)

```bash
git clone <this-repo> tunforge
cd tunforge
sudo ./install.sh
```

Установщик:

1. Preflight: Ubuntu 22.04 / `--force` для других, root, arch (amd64 / arm64), наличие `systemd-resolved`.
2. Apt: ставит только недостающее — `wireguard-tools openvpn nftables whiptail iproute2 curl jq gawk dnsutils ca-certificates moreutils`.
3. sing-box: последний `.deb` с GitHub Releases, проверка SHA256 при наличии `.sha256`, затем `dpkg -i`. Пропуск: `--no-singbox`; офлайн: `--singbox-deb /path/to/file.deb`.
4. Бинарники в `/usr/local/bin/`, библиотеки в `/usr/local/lib/tunforge/`, конфиги в `/etc/tunforge/`.
5. Drop-in для `NetworkManager` и `systemd-resolved`; `/etc/resolv.conf` на stub systemd (с бэкапом).
6. Включает `tunforge-killswitch.service` — перезагрузка в середине VPN не даст утечку.

Повторный запуск безопасен (идемпотентно). `--check` — сухой прогон.

```bash
sudo ./install.sh --check
sudo ./install.sh --no-singbox
sudo ./install.sh --singbox-deb ./sing-box_1.10.3_linux_amd64.deb
```

### Удаление

```bash
sudo ./uninstall.sh           # удаляет Tunforge, сохраняет профили и конфиги
sudo ./uninstall.sh --purge   # также очищает /etc/tunforge и /var/lib/tunforge
```

Пакеты Apt остаются. В конце выводится подсказка по удалению.

### Быстрый старт

1. Положите конфиги:

   - WireGuard: `/etc/tunforge/configs/wireguard/de1.conf` (chmod 600 — приватный ключ)
   - OpenVPN: `/etc/tunforge/configs/openvpn/nl1.ovpn`
   - sing-box: `/etc/tunforge/configs/singbox/jp1.json`

   Для URI в стиле V2Ray (`vmess://`, `vless://`, `trojan://`, `ss://`) пропустите шаг 1:

   ```bash
   sudo tunforge import 'vless://uuid@server:443?security=tls&type=ws&path=/api#JP-Tokyo'
   ```

2. Создайте дескриптор в `/etc/tunforge/profiles/<name>.profile`:

   ```bash
   sudo tunforge scaffold
   ```

   Или TUI: **Manage profiles → Scaffold from existing configs**. Существующие профили не перезаписываются.

3. Запуск:

   ```bash
   sudo tunforge
   ```

   - **Connect** — переключение профилей
   - **Disconnect** — возврат в direct
   - **Status** — активный профиль, iface, DNS, публичный IP через туннель
   - **Live logs** — цветной tail journald
   - **Doctor** — проверка здоровья + dump правил kill switch

CLI для скриптов:

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

### Импорт V2Ray URI

```bash
sudo tunforge import 'vless://...#JP-Tokyo'
sudo tunforge import 'vmess://eyJ2I...' jp-tokyo
echo "$URI" | sudo tunforge import -
sudo tunforge import -f ~/subs.txt
```

После импорта при необходимости отредактируйте DNS в `/etc/tunforge/profiles/<name>.profile`:

```bash
sudo tunforge connect <name>
```

### Подписки V2Ray (soft sub)

*Подписка* — удалённый URL со **списком** URI V2Ray. Сохраните URL и **обновляйте** для актуального списка серверов.

```bash
sudo tunforge subscription add https://provider.example/sub?token=abc myprovider
sudo tunforge subscription update myprovider
sudo tunforge subscription update all
sudo tunforge subscription list
sudo tunforge subscription remove myprovider
```

### Файл профиля

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

### Защита от утечек

| Слой | Механизм |
|---|---|
| DNS | Per-link lock через `resolvectl`; только VPN iface — resolver |
| Маршруты | Default route через туннель |
| Kill switch | Таблица `inet tunforge`, `output policy drop` |
| IPv6 | Отключение sysctl при VPN |
| Загрузка | `tunforge-killswitch.service` до NetworkManager |
| Проверка после connect | `verify.sh`; сбой → откат к direct |

#### Обход для локальной разработки

По умолчанию: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`.

```bash
sudo tunforge bypass add-cidr 172.17.0.0/16
sudo tunforge bypass add-domain backend.local
tunforge bypass list
```

#### Почему запрещён Google DNS

`8.8.8.8` и `8.8.4.4` — тот же вендор, что Gmail / Workspace / Firebase. Загрузчик профиля жёстко отклоняет их. Используйте Cloudflare (`1.1.1.1`), Quad9 (`9.9.9.9`) и т.д.

### Что не решается (уровень браузера)

- **WebRTC** — STUN может раскрыть реальный IP
- **Отпечаток браузера** — canvas, шрифты, часовой пояс
- **Корреляция аккаунтов** — отдельные профили браузера на каждый exit
- **HTTP/3 (QUIC)** — при kill switch UDP/443 вне туннеля отбрасывается

### Структура


Как в английской версии: `/usr/local/bin/`, `/usr/local/lib/tunforge/`, `/etc/tunforge/`, `/var/lib/tunforge/`.

### Участие в разработке

Приветствуются исправления багов, усиление защиты от утечек, новые коннекторы и документация.

1. Fork и ветка (`feat/…`, `fix/…`, `docs/…`)
2. Один concern на PR
3. Тесты на Ubuntu 22.04 для сети/DNS/firewall
4. PR с описанием проблемы, подхода и проверки

### Устранение неполадок

```bash
sudo tunforge doctor
sudo tunforge logs
sudo tunforge disconnect
sudo nft list table inet tunforge
resolvectl status
ip -4 route get 1.1.1.1
```

Причина отката `verify.sh`: `journalctl -t tunforge -n 50`.
