[English](README.md) | فارسی

# StarSpeed Tunnel

ابزار تعاملی و ایمن برای ساخت تونل چندلاین Reverse SSH از طریق سرور ایران به
Inboundهای موجود Xray/3x-ui. این ابزار HAProxy، لاین‌های SSH و سرویس‌های systemd
را مدیریت می‌کند و کانفیگ Xray/3x-ui را تغییر نمی‌دهد.

## قابلیت‌های اصلی

- چهار لاین مستقل Reverse SSH برای هر سرور خارج.
- توزیع Round-robin و Failover توسط HAProxy.
- راه‌اندازی هدایت‌شده برای یک سرور ایران و حداکثر دو سرور خارج.
- اعتبارسنجی و Backup زمان‌دار پیش از تغییر HAProxy.
- اجرای مجدد، تعمیر و حذف به‌صورت Idempotent.
- بررسی سخت‌گیرانه Host Key و Setup Code بدون اطلاعات محرمانه.
- ثبت خودکار کلید، راه‌اندازی Laneها و کنترل آماده‌بودن با Retry محدود.
- رابط CLI فقط انگلیسی برای نمایش صحیح در ترمینال SSH.

## نصب و اجرای سریع

### Install & Run (curl — Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash
```

### Install & Run (wget — Alternative)

```bash
wget -qO- https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash
```

### Run Only (Already Installed)

```bash
sudo /usr/local/sbin/starspeed-tunnel
```

نصب‌کننده ابتدا دانلود کامل را اعتبارسنجی و سپس فایل را به‌صورت اتمیک در
`/usr/local/sbin/starspeed-tunnel` نصب می‌کند. نصب مجدد فقط فایل اجرایی را به‌روز
می‌کند و تنظیمات `/etc/starspeed-tunnel` حفظ می‌شوند.

## سیستم‌عامل‌های پشتیبانی‌شده

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Ubuntu 26.04 LTS

پیش‌نیازها Bash، systemd، OpenSSH و HAProxy هستند. پکیج‌های Runtime مفقود را
می‌توان با APT نصب کرد. ابزار قوانین UFW، nftables یا iptables را تغییر نمی‌دهد.

## نحوه کار

```text
Client -> Iran public frontend -> HAProxy -> 4 reverse-SSH lanes
       -> Foreign server -> existing Xray inbound
```

سرور ایران Frontend عمومی و تخصیص Laneها را نگه می‌دارد. هر سرور خارج کلید SSH،
Host Key پین‌شده ایران، چهار سرویس systemd و مقصد Xray مستقل خودش را دارد.

## راهنمای پیکربندی

1. روی ایران گزینه `1) Setup Iran Server` را انتخاب و برای هر سرور خارج فقط پورت
   عمومی Tunnel را وارد کنید؛ پورت‌های داخلی Lane خودکار تخصیص داده می‌شوند و
   ورودی کاربر نیستند. سپس Setup Code را کپی کنید.
2. اثرانگشت SSH سرور ایران را از یک مسیر مطمئن بررسی کنید. اتصال مدیریتی می‌تواند
   از `ssh-agent`، کلید مشخص‌شده با `SST_ADMIN_IDENTITY` یا یک‌بار ورود امن رمز
   از طریق خود OpenSSH استفاده کند؛ رمز ذخیره نمی‌شود.
3. گزینه `2) Setup Foreign Server` را اجرا و Setup Code، آدرس ایران، پورت واقعی
   Inbound محلی Xray و اثرانگشت SHA256 تأییدشده را وارد کنید. ابزار کلید محدود
   اختصاصی را خودکار ثبت می‌کند،
   فقط Laneهای همان Node را بالا می‌آورد و Reverse Listenerها، HAProxy، Frontend،
   TCP و در صورت تشخیص WebSocket را کنترل می‌کند.
4. فقط بعد از عبور همه کنترل‌های لازم پیام `Tunnel Ready` نمایش داده می‌شود.
   گزینه `3` صرفاً برای بازیابی پیشرفته باقی مانده است.

Inbound مربوط به Xray باید از قبل ساخته شده و در حال Listen باشد. Setup Code فقط
تخصیص پورت‌ها را حمل می‌کند و شامل رمز یا کلید خصوصی نیست.

## استفاده پیشرفته

| گزینه | عملکرد |
| --- | --- |
| `1` | تنظیم Frontend ایران و Laneهای HAProxy |
| `2` | تنظیم سرور خارج با Setup Code |
| `3` | افزودن کلید عمومی SSH خارج روی ایران |
| `4` | نمایش وضعیت فقط‌خواندنی تونل |
| `5` | عیب‌یابی و سپس پیشنهاد تعمیر محدود |
| `6` | حذف یک تونل خارج |
| `7` | نمایش راهنمای داخلی |
| `8` | نمایش اطلاعات سازگاری زبان |
| `9` | حذف فقط فایل‌های مدیریت‌شده StarSpeed |

گزینه‌های کاربردی:

```bash
sudo /usr/local/sbin/starspeed-tunnel --status
sudo /usr/local/sbin/starspeed-tunnel --setup-code 1
sudo /usr/local/sbin/starspeed-tunnel --role
sudo /usr/local/sbin/starspeed-tunnel --help
```

رابط CLI فقط انگلیسی است. `--lang en` عادی کار می‌کند؛ `--lang fa` برای سازگاری
قدیمی پذیرفته می‌شود، پیام انگلیسی کوتاهی نشان می‌دهد و منوی انگلیسی را باز می‌کند.

فایل‌های مدیریت‌شده زیر `/etc/starspeed-tunnel` قرار دارند و سرویس Laneها با الگوی
`starspeed-tunnel-f<N>-lane<M>.service` ساخته می‌شوند. اطلاعات SSH خارج در
`/root/.ssh/starspeed-tunnel_*` قرار می‌گیرد. Xray/3x-ui فقط‌خواندنی باقی می‌ماند.
جزئیات Laneها در وضعیت عادی مخفی است؛ فقط برای عیب‌یابی پیشرفته از دستور
`sudo env SST_ADVANCED_STATUS=1 /usr/local/sbin/starspeed-tunnel --status` استفاده کنید.

## عیب‌یابی

1. ابتدا گزینه `4) Tunnel Status` را اجرا کنید.
2. اگر HAProxy یا Frontend مشکل دارد، کانفیگ را اعتبارسنجی کنید:

   ```bash
   sudo haproxy -c -f /etc/haproxy/haproxy.cfg
   ```

3. گزینه `5) Diagnose & Repair` می‌تواند Fragment یا Unit مدیریت‌شده را از State
   بازسازی یا Backup سالم را بازیابی کند.

خطاهای رایج:

- `nothing is listening on 127.0.0.1:<port>`: Inbound خارجی Listen نیست؛ ابزار آن
  را نمی‌سازد یا تغییر نمی‌دهد.
- `Lane N: DOWN`: سرویس systemd همان Lane را روی سرور خارج بررسی کنید.
- `host key not pinned`: اثرانگشت SHA256 نمایش‌داده‌شده را خارج از مسیر SSH تأیید
  کنید؛ کلید ناشناخته یا تغییریافته خودکار پذیرفته نمی‌شود.
- `automatic SSH authorization failed`: کلید مدیریتی مجاز ایران را داخل
  `ssh-agent` بارگذاری کنید، موقتاً `SST_ADMIN_IDENTITY=/secure/key/path` بدهید یا
  از Prompt یک‌باره رمز OpenSSH استفاده کنید؛ اطلاعات ورود ذخیره نمی‌شود.

تست‌ها در Sandboxهای موقت اجرا می‌شوند:

```bash
bash tests/run-tests.sh
bash tests/syntax-check.sh
```

## مجوز

MIT — متن کامل در [LICENSE](LICENSE) موجود است.
