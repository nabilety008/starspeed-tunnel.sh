[English](README.md) | فارسی

# StarSpeed Tunnel

## ۱. معرفی

نصب‌کننده‌ی تعاملی برای یک **تونل Reverse SSH چند-لاین (multi-lane)** از طریق سرور
ایران. هدف این ابزار، انتقال ترافیک Xray/3x-ui از یک یا دو سرور خارجی (Foreign)
است، **بدون اینکه کوچک‌ترین تغییری در کانفیگ خود Xray/3x-ui داده شود.**

```
Client -> پورت Frontend عمومی روی ایران -> HAProxy -> ۴ لاین Reverse SSH
       -> سرور Foreign -> inbound موجود Xray
```

به هر سرور Foreign چهار **لاین Reverse SSH مستقل** اختصاص داده می‌شود. HAProxy بین
آن‌ها به‌صورت round-robin توزیع می‌کند، بنابراین از کار افتادن یک لاین، تونل را از
کار نمی‌اندازد. Foreign #1 و Foreign #2 کاملاً مستقل هستند: Frontend جدا، مقصد Xray
جدا، بلوک Lane جدا، کلید SSH جدا، `known_hosts` جدا، state جدا و unitهای `systemd`
جدا.

نسخه‌ی 1.1.0 منوی انگلیسی، ویزاردهای گام‌به‌گام با خلاصه‌ی
تأیید پیش از اعمال، هدر وضعیت در یک نگاه، و جریان «عیب‌یابی فقط-خواندنی» را اضافه
می‌کند.

## ۲. قابلیت‌ها

* **دو ویزارد راهنما** - یکی برای سمت ایران و یکی برای هر سرور Foreign.
* **رابط خط فرمان فقط انگلیسی** - برای جلوگیری از مشکل RTL/BiDi در ترمینال SSH.
* **Setup Code** - یک رشته‌ی base64 کوتاه که تخصیص هر Foreign را حمل می‌کند؛ بدون
  هیچ اطلاعات محرمانه.
* **چهار لاین Reverse SSH برای هر Foreign** با توزیع `roundrobin` در HAProxy؛ از کار
  افتادن یک لاین باعث قطع شدن تونل نمی‌شود.
* **امن به‌صورت ساختاری** - کانفیگ نامزد HAProxy پیش از فعال‌سازی با `haproxy -c`
  اعتبارسنجی می‌شود و از کانفیگ فعال نسخه‌ی پشتیبان گرفته می‌شود.
* **اجرای مجدد بی‌خطر (idempotent)** - اجرای دوباره‌ی Setup، Repair یا Uninstall
  باعث ساختن unit یا بلوک تکراری نمی‌شود.
* **وضعیت شفاف** - Frontend هر Foreign، مقصد Xray، وضعیت هر Lane و سلامت HAProxy،
  بدون چاپ هیچ اطلاعات محرمانه.
* **عیب‌یابی فقط-خواندنی در ابتدا** - Repair پیش از درخواست اجازه، مشکلات را گزارش
  می‌کند.

## ۳. معماری

```
+---------+   عمومی      +----------+  Reverse SSH   +-----------+
| Client  | --> :FRONTEND |  ایران   | ==== LANE1..4=> |  Foreign  |
+---------+               |  HAProxy |= round robin == |  Xray in  |
                          +----------+                +-----------+
```

* Client به یک **پورت Frontend عمومی روی ایران** وصل می‌شود.
* HAProxy آن Frontend را بین **چهار لاین Reverse SSH** توزیع می‌کند.
* هر لاین یک فوروارد `ssh -R` از سرور Foreign به ایران است.
* سرور Foreign لاین را به **inbound موجود Xray خودش** هدایت می‌کند.

ترافیک به‌صورت TCP خام منتقل می‌شود؛ HAProxy فقط یک تونل شفاف TCP فراهم می‌کند و
پروتکل داخلی شما (VLESS یا هر پروتکل دیگر) دست‌نخورده باقی می‌ماند.

## ۴. این اسکریپت چه کارهایی انجام نمی‌دهد

این ابزار **فقط Xray / 3x-ui را می‌خواند** و هیچ‌گاه آن را تغییر نمی‌دهد.

* هرگز inbound مربوط به Xray را نمی‌سازد، ویرایش نمی‌کند و حذف نمی‌کند.
* هرگز کانفیگ موجود `Direct` را دست نمی‌زند.
* هرگز بررسی host key را غیرفعال نمی‌کند.
* هرگز سرعت جعلی تولید نمی‌کند، ترافیک را شکل‌دهی (shaping) نمی‌کند و تأخیر مصنوعی
  اضافه نمی‌کند. هیچ قابلیتی مثل fake upload، تولید ترافیک معکوس، iperf یا «آپلود ۱
  درصد» وجود ندارد.

inbound مربوط به Xray شما باید از قبل وجود داشته باشد و در حال Listen باشد؛
نصب‌کننده آن را بررسی می‌کند و در غیر این صورت ادامه نمی‌دهد.

## ۵. پیش‌نیازها

* Ubuntu 22.04 / 24.04 با `systemd`، کلاینت OpenSSH و HAProxy.
* نصب‌کننده در صورت نبود پکیج‌های لازم، پیشنهاد می‌دهد آن‌ها را با `apt-get` نصب کند.

| Host    | Role     | نیازمندی                                 |
| ------- | -------- | ---------------------------------------- |
| Iran    | frontend | IP عمومی، HAProxy، سرور OpenSSH           |
| Foreign | backend  | کلاینت OpenSSH، یک inbound موجود از Xray  |

## ۶. نصب / دانلود

نصب و اجرای منوی انگلیسی با فرمان سازگار قدیمی:

```bash
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash -s -- --lang fa
```

گزینه‌ی `--lang fa` برای سازگاری حفظ شده است، اما یک پیام کوتاه انگلیسی نمایش
می‌دهد و منوی انگلیسی را اجرا می‌کند. رابط فارسی دیگر ارائه نمی‌شود.

فرمان جایگزین با `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash -s -- --lang fa
```

نصب و اجرای منوی انگلیسی:

```bash
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash -s -- --lang en
```

حالت پیش‌فرض (انگلیسی):

```bash
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash
```

فرمان‌های معادل با `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash -s -- --lang en
wget -qO- https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/install.sh | sudo bash
```

Bootstrap ابتدا فایل اصلی را کامل در یک فایل موقت دانلود و با Bash اعتبارسنجی می‌کند،
سپس آن را به‌صورت اتمیک در `/usr/local/sbin/starspeed-tunnel` نصب می‌کند. اجرای مجدد
فقط فایل اجرایی را به‌روز می‌کند و تنظیمات موجود در `/etc/starspeed-tunnel` حفظ
می‌شوند. سیستم‌های پشتیبانی‌شده Ubuntu 22.04 و 24.04 هستند و نصب‌کننده‌ی اصلی در
صورت نیاز نصب پکیج‌های runtime را با APT پیشنهاد می‌دهد.
Bootstrap باید با root (معمولاً `sudo`) اجرا شود و وجود `curl` یا `wget` الزامی است.

اجرای مجدد پس از نصب:

```bash
sudo starspeed-tunnel
```

روش نصب دستی همچنان پشتیبانی می‌شود:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o starspeed-tunnel.sh
chmod +x starspeed-tunnel.sh
sudo ./starspeed-tunnel.sh
```

## ۷. شروع سریع

سه گام کوتاه، به این ترتیب:

1. **روی ایران** گزینه‌ی `1) Setup Iran Server` را بزنید، بگویید چند سرور Foreign دارید
   و خلاصه را تأیید کنید. هر **Setup Code** چاپ‌شده را کپی کنید.
2. **روی هر سرور Foreign** گزینه‌ی `2) Setup Foreign Server` را بزنید، Setup Code را
   جای‌گذاری کنید و آدرس ایران را وارد کنید. Foreign کلید عمومی SSH خودش را چاپ می‌کند.
3. **دوباره روی ایران** گزینه‌ی `3) Authorize Foreign SSH Key` را بزنید و همان کلید
   عمومی را جای‌گذاری کنید. تونل حالا فعال است.

## ۸. راه‌اندازی سرور ایران

گزینه‌ی **`1) Setup Iran Server`** را انتخاب کنید. ویزارد:

* پیکربندی موجود را نشان می‌دهد و تخصیص پورت آن را بدون تغییر دوباره استفاده می‌کند؛
* می‌پرسد چند سرور Foreign از ایران عبور می‌کنند (۱ یا ۲)؛
* برای هر Foreign **جدید** یک پورت Frontend عمومی روی ایران و پورت inbound Xray روی
  سرور Foreign می‌پرسد؛
* برای هر Foreign یک بلوک چهار پورت آزاد به‌عنوان Lane تخصیص می‌دهد؛
* **خلاصه‌ی پیکربندی** را چاپ کرده و برای تأیید می‌پرسد؛
* و **تنها پس از تأیید** state را می‌نویسد، fragmentها را می‌سازد، کل کانفیگ نامزد را با
  `haproxy -c` اعتبارسنجی می‌کند، از کانفیگ فعال backup می‌گیرد و آن را reload می‌کند.

اگر تأیید را رد کنید، هیچ چیزی نوشته نمی‌شود و هیچ تغییری اعمال نمی‌گردد.

پورت‌های Lane با **اسکن** از پایه‌ی `46000` و گام `100` تخصیص داده می‌شوند (نه
hard-code)؛ بنابراین Foreign #1 معمولاً `46101` تا `46104` و Foreign #2 معمولاً
`46201` تا `46204` می‌گیرد.

## ۹. راه‌اندازی Foreign

گزینه‌ی **`2) Setup Foreign Server`** را انتخاب کنید. ویزارد **کد-محور (code-first)**
است:

* **Setup Code** دریافتی از ایران را جای‌گذاری کنید؛ شماره‌ی Foreign، Frontend و تخصیص
  Lane مستقیماً از خود کد خوانده می‌شوند؛
* اگر این سرور از قبل پیکربندی شده باشد، می‌توانید پیکربندی موجود را نگه دارید یا آن را
  بازنویسی کنید (رد کردن بازنویسی هیچ چیزی را تغییر نمی‌دهد)؛
* **آدرس ایران** را وارد کنید (کد آن را حمل نمی‌کند)؛
* برای اعمال، خلاصه را تأیید کنید.

سپس سمت Foreign یک جفت‌کلید SSH می‌سازد، host key ایران را با `ssh-keyscan` pin
می‌کند و چهار unit سخت‌گیرانه‌ی `systemd` با نام
`starspeed-tunnel-f<N>-lane<M>.service` نصب می‌کند. این unitها هرگز برای رمز عبور
منتظر نمی‌مانند:

```
BatchMode=yes
ExitOnForwardFailure=yes
ServerAliveInterval=15
ServerAliveCountMax=3
TCPKeepAlive=yes
StrictHostKeyChecking=yes
Restart=always
WantedBy=multi-user.target
```

اگر `ssh-keyscan` نتواند host key ایران را بگیرد، اسکریپت خطا می‌دهد و با یک
`known_hosts` خالی ادامه نمی‌دهد.

## ۱۰. مجوز دادن به کلید SSH

سرور Foreign کلید **عمومی** SSH خودش را چاپ می‌کند. روی ایران گزینه‌ی
**`3) Authorize Foreign SSH Key`** را انتخاب کرده و کلید را جای‌گذاری کنید (یا `q` برای
پایان). **کلید خصوصی هرگز از سرور Foreign خارج نمی‌شود.**

## ۱۱. وضعیت (Status)

گزینه‌ی **`4) Tunnel Status`** یا فرمان `--status`. هدر، نقش شما، تعداد Foreignهای
پیکربندی‌شده و HAProxy (روی ایران) یا تعداد لاین‌های فعال (روی Foreign) را نشان
می‌دهد. برای هر Foreign:

* پورت Frontend و مقصد Xray؛
* وضعیت هر Lane؛
* سلامت HAProxy و معتبر بودن کانفیگ (روی ایران)؛
* تعداد کلیدهای مجاز SSH روی ایران، یا وجود host key ایران روی Foreign.

Status **فقط-خواندنی** است و هرگز محتوای Private Key را چاپ نمی‌کند. همچنین آخرین
خطاهای لاگ نصب را نشان می‌دهد.

## ۱۲. عیب‌یابی و تعمیر (Diagnose & Repair)

گزینه‌ی **`5) Diagnose & Repair`**. ابتدا **بررسی‌های فقط-خواندنی** اجرا می‌شود و
فهرست تغییرات پیشنهادی چاپ می‌گردد؛ تا تأیید شما هیچ‌چیز تغییر نمی‌کند. این گزینه
می‌تواند:

* یک state خراب را حذف کند (با تأیید)؛
* یک fragment یا unit حذف‌شده را از روی state بازسازی کند؛
* آخرین backup سالم HAProxy را وقتی کانفیگ فعال دیگر اعتبارسنجی نمی‌شود بازیابی کند؛
* یک Frontend که Listen نمی‌کند را دوباره bind کند.

## ۱۳. حذف یک Foreign و Uninstall

* **`6) Remove Foreign Tunnel`** فقط یک Foreign را حذف می‌کند: state، fragment،
  unitهای Lane و بخش بلوک مدیریت‌شده‌ی آن. سایر Foreignها دست‌نخورده می‌مانند.
* **`9) Uninstall`** فقط فایل‌هایی را حذف می‌کند که این پروژه ساخته است - unitهای
  Lane، state، fragmentهای تولیدشده و بلوک مدیریت‌شده داخل `haproxy.cfg`. کانفیگ
  نامرتبط HAProxy و هر چیزی متعلق به Xray / 3x-ui دست‌نخورده می‌ماند. جفت‌کلید SSH
  به‌صورت پیش‌فرض نگه داشته می‌شود.

## ۱۴. مرجع منو و زبان

| گزینه | کار |
| ------ | --- |
| `1` | Setup Iran Server - تخصیص Frontend/Lane و نوشتن کانفیگ HAProxy |
| `2` | Setup Foreign Server - روی سرور Foreign اجرا می‌شود (کد-محور) |
| `3` | Authorize Foreign SSH Key - روی ایران اجرا می‌شود |
| `4` | Tunnel Status - Laneها، Frontendها و سلامت HAProxy |
| `5` | Diagnose & Repair - ابتدا بررسی فقط-خواندنی، سپس تعمیر |
| `6` | Remove Foreign Tunnel - حذف فقط یک Foreign |
| `7` | Help & Documentation - معماری، پورت‌ها، Setup Code |
| `8` | Settings & Language - اطلاعات رابط انگلیسی |
| `9` | Uninstall - حذف فقط فایل‌های StarSpeed |
| `0` | خروج |

فرمان‌های خط فرمان:

```bash
sudo ./starspeed-tunnel.sh            # interactive menu
sudo ./starspeed-tunnel.sh --status   # status only, no changes
sudo ./starspeed-tunnel.sh --setup-code 1
sudo ./starspeed-tunnel.sh --role
sudo ./starspeed-tunnel.sh --lang fa  # compatibility notice; uses English
sudo ./starspeed-tunnel.sh --version
sudo ./starspeed-tunnel.sh --help     # full option list
```

**زبان:** رابط CLI فقط **انگلیسی** است تا در ترمینال‌های SSH بدون مشکل RTL/BiDi
نمایش داده شود. `--lang en` عادی کار می‌کند. گزینه‌ی `--lang fa`، تنظیم قدیمی
`fa`، متغیر `SST_LANG=fa` و locale فارسی پذیرفته می‌شوند، اما خروجی همچنان
انگلیسی است. فقط مستندات فارسی در همین فایل حفظ شده‌اند.

## ۱۵. امنیت، فایل‌ها، تست، عیب‌یابی و لایسنس

**ویژگی‌های امنیتی**

* **اعتبارسنجی HAProxy پیش از فعال‌سازی.** کانفیگ نامزد با `haproxy -c` بررسی می‌شود؛
  اگر ناموفق بود، کانفیگ فعال دست‌نخورده می‌ماند.
* **Backup پیش از هر بازنویسی** در `/etc/starspeed-tunnel/backups`.
* **حفظ کانفیگ شخصی شما.** فقط یک بلوک مدیریت‌شده‌ی محدودشده
  (`# >>> starspeed-tunnel managed includes >>>` /
  `# <<< starspeed-tunnel managed includes <<<`) نوشته، جایگزین یا حذف می‌شود؛ اجرای
  مجدد byte-stable است.
* **بررسی سخت‌گیرانه‌ی host key همیشه فعال است.** هر Foreign، host key ایران را در
  `known_hosts` مخصوص خودش pin می‌کند.
* **Setup Code هیچ اطلاعات محرمانه‌ای ندارد** - فقط تخصیص (شماره، Frontend، Laneها،
  پورت SSH).
* **فایل‌های state داده هستند، نه کد.** مقادیر اعتبارسنجی می‌شوند و هرگز `eval`
  نمی‌گردند.
* **Xray / 3x-ui فقط-خواندنی است** - ابزار هرگز inbound نمی‌سازد/ویرایش/حذف می‌کند،
  host-key checking را غیرفعال نمی‌کند و هیچ shaping یا تأخیر مصنوعی ندارد.

**فایل‌هایی که مدیریت می‌شوند**

```
/etc/starspeed-tunnel/
  state/foreign-N.env        وضعیت ذخیره‌شده هر Foreign
  state/role                 iran | foreign
  lang                       زبان ذخیره‌شده
  haproxy/foreign-N.cfg      fragment مربوط به هر Foreign
  backups/                   نسخه‌های پشتیبان دارای زمان
  install.log                فایل لاگ
/etc/systemd/system/starspeed-tunnel-f<N>-lane<M>.service
/root/.ssh/starspeed-tunnel_f<N>        کلید خصوصی (فقط روی Foreign)
/root/.ssh/starspeed-tunnel_f<N>.pub    کلید عمومی (فقط روی Foreign)
/root/.ssh/starspeed-tunnel_iran<N>    host key پین‌شده‌ی ایران (فقط روی Foreign)
```

**تست (Testing)** - مجموعه‌ی تست کاملاً در محیط‌های موقت (sandbox) با نسخه‌های ساختگی
`systemctl`، `ss`، `haproxy` و `ssh-keyscan` اجرا می‌شود و هرگز به `/etc` واقعی،
systemd واقعی، HAProxy واقعی، شبکه یا SSH واقعی دست نمی‌زند.

```bash
bash tests/run-tests.sh          # everything
bash tests/run-tests.sh unit     # validation/allocation/state only
bash tests/syntax-check.sh       # bash -n over every shell file
```

**عیب‌یابی (Troubleshooting)** - ابتدا **`4) Tunnel Status`** را اجرا کنید. اگر HAProxy
بالا نمی‌آید:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

سپس **`5) Diagnose & Repair`** را اجرا کنید تا fragment یا unit حذف‌شده از روی state
بازسازی شود یا آخرین backup سالم بازیابی گردد.

موارد رایج:

* **`nothing is listening on 127.0.0.1:<port>`** - inbound مربوط به Xray روی سرور
  Foreign وجود ندارد یا Listen نیست (این ابزار آن را تغییر نمی‌دهد).
* **`Lane N: DOWN`** - روی Foreign سرویس مربوطه فعال نیست:
  `sudo systemctl status starspeed-tunnel-f1-lane1.service`
* **`host key not pinned`** - مطمئن شوید `ssh-keyscan` از Foreign به ایران دسترسی
  دارد. ادامه با `known_hosts` خالی عمداً مجاز نیست.

**لایسنس** - این پروژه تحت لایسنس MIT منتشر می‌شود. متن کامل در [LICENSE](LICENSE).

## ❤️ حمایت از StarSpeed Tunnel

اگر StarSpeed Tunnel برای شما مفید بوده و مایلید از ادامه توسعه آن حمایت کنید،
می‌توانید به توسعه قابلیت‌های آینده، نگهداری، تست و انتشار نسخه‌های بعدی پروژه
کمک کنید.

### 🇮🇷 حمایت از داخل ایران

[حمایت از starspeed-tunnel در حامی‌باش](https://hamibash.com/nabilety008)

### 🌍 حمایت بین‌المللی

**USDT — BNB Smart Chain (BEP20)**

`0x3A09DAc6A09A3760F063EBfBF6D523737BD498A5`

**USDT — TRON (TRC20)**

`TEmsoP2M9gZBymrc73z8NXdcy4LK2Qzkig`

> قبل از ارسال، آدرس کیف پول و شبکه انتخاب‌شده را با دقت بررسی کنید.
> تراکنش‌های ارز دیجیتال ممکن است غیرقابل بازگشت باشند.
