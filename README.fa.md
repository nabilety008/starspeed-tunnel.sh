[English](README.md) | فارسی

# starspeed-tunnel

## معرفی

نصب‌کننده‌ی تعاملی برای **تونل Reverse SSH چند-لاین (multi-lane)** از طریق یک سرور ایران.
هدف این ابزار، انتقال ترافیک Xray/3x-ui به یک یا دو سرور خارجی (Foreign) است، بدون
اینکه کوچک‌ترین تغییری در کانفیگ خود Xray/3x-ui داده شود.

```
Client -> Iran public frontend port -> HAProxy -> 4 local reverse-SSH lanes
       -> Foreign server -> existing Xray inbound
```

به هر سرور Foreign چهار **لاین Reverse SSH مستقل** اختصاص داده می‌شود. HAProxy بین
آن‌ها به‌صورت round-robin توزیع می‌کند، بنابراین از کار افتادن یک لاین، تونل را از کار
نمی‌اندازد.

این پروژه از **یک سرور ایران** و **یک یا دو سرور Foreign** پشتیبانی می‌کند:

* هر Foreign چهار لاین Reverse SSH مستقل دارد.
* هر Foreign می‌تواند **پورت inbound متفاوتی در Xray** داشته باشد.
* هر Foreign **پورت Frontend خودش روی ایران** را دارد.
* Foreign #1 و Foreign #2 کاملاً مستقل هستند: Frontend جدا، مقصد Xray جدا، بلوک
  Lane جدا، کلید SSH جدا، فایل `known_hosts` جدا، state ذخیره‌شده‌ی جدا و unitهای
  `systemd` جدا.

## این اسکریپت چه کارهایی انجام نمی‌دهد

این ابزار **فقط Xray / 3x-ui را می‌خواند** و هیچ‌گاه آن را تغییر نمی‌دهد.

* هرگز inbound مربوط به Xray را نمی‌سازد، ویرایش نمی‌کند و حذف نمی‌کند.
* هرگز کانفیگ موجود `Direct` را دست نمی‌زند.
* هرگز سرعت جعلی تولید نمی‌کند، ترافیک را شکل‌دهی (shaping) نمی‌کند و تأخیر مصنوعی
  اضافه نمی‌کند.
* هرگز بررسی host key را غیرفعال نمی‌کند.
* **هیچ قابلیتی مثل fake upload، تولید ترافیک معکوس، iperf یا «آپلود ۱ درصد» وجود
  ندارد.** چنین چیزی در این پروژه پیاده‌سازی نشده است.

inbound مربوط به Xray شما باید از قبل وجود داشته باشد و از قبل در حال Listen باشد؛
نصب‌کننده آن را بررسی می‌کند و در غیر این صورت ادامه نمی‌دهد.

## معماری

```
Client
  -> Iran frontend   (پورت عمومی روی سرور ایران)
  -> HAProxy         (round-robin بین ۴ لاین)
  -> 4 Reverse SSH lanes
  -> Foreign server
  -> existing Xray inbound  (پورت inbound موجود روی سرور Foreign)
```

جریان داده به‌صورت TCP خام منتقل می‌شود. یعنی HAProxy فقط یک تونل شفاف TCP به سمت
inbound موجود Xray فراهم می‌کند و پروتکل داخلی شما (مثلاً VLESS یا هر پروتکل دیگر)
دست‌نخورده باقی می‌ماند.

## قابلیت‌ها

* **چهار لاین مستقل برای هر Foreign** با توزیع `roundrobin` در HAProxy؛ از کار افتادن
  یک لاین باعث قطع شدن تونل نمی‌شود.
* **پشتیبانی از یک سرور ایران و یک یا دو سرور Foreign** با پیکربندی کاملاً مستقل
  برای هر Foreign.
* **راه‌اندازی تعاملی از طریق منو**؛ همه‌ی مراحل راهنمایی می‌شوند.
* **تخصیص خودکار پورت‌های Lane** با اسکن از یک پایه‌ی مشخص، به‌گونه‌ای که از پورت‌های
  اشغال‌شده و تداخل با Frontend جلوگیری شود.
* **اعتبارسنجی کانفیگ با `haproxy -c`** پیش از فعال‌سازی؛ در صورت ناموفق بودن، کانفیگ
  فعال قبلی دست‌نخورده می‌ماند.
* **Backup خودکار با ذکر زمان** پیش از هر بازنویسی، در
  `/etc/starspeed-tunnel/backups`.
* **دست‌نخورده ماندن کانفیگ شخصی HAProxy**؛ فقط یک بلوک مدیریت‌شده نوشته یا حذف
  می‌شود.
* **کلید اختصاصی ED25519 برای هر Foreign**؛ کلید خصوصی هرگز از سرور Foreign خارج
  نمی‌شود و فقط **Public Key** به ایران داده می‌شود.
* **قفل کردن host key ایران** در `known_hosts` اختصاصی، با حفظ
  `StrictHostKeyChecking=yes`.
* **چهار unit مستقل `systemd`** برای هر Foreign، با `Restart=always` و
  `WantedBy=multi-user.target` تا پس از ری‌استارت خودکار بالا بیایند.
* **Setup Code** برای انتقال تنظیمات به سرور Foreign، بدون حمل هیچ رمز یا کلیدی.
* **ارائه‌ی دستورهای غیرتعاملی** مانند `--status`، `--setup-code`، `--role` و
  `--version` برای اسکریپت‌های خودکارسازی.
* **اجرای مجدد بدون مشکل (idempotent)**؛ اجرای دوباره‌ی Setup، Repair یا Uninstall
  باعث ساختن unit یا include تکراری نمی‌شود.
* **عدم تغییر در Xray/3x-ui و کانفیگ `Direct`**؛ ابزار فقط وضعیت را می‌خواند.

## پیش‌نیازها

* Ubuntu 22.04 / 24.04 با `systemd`، کلاینت OpenSSH و HAProxy.
* نصب‌کننده در صورت نبود پکیج‌های لازم، پیشنهاد می‌دهد آن‌ها را با `apt-get` نصب کند.

| Host    | Role     | نیازمندی                                                        |
| ------- | -------- | --------------------------------------------------------------- |
| Iran    | frontend | IP عمومی، HAProxy، سرور OpenSSH                                   |
| Foreign | backend  | کلاینت OpenSSH، یک inbound موجود از Xray                         |

پیش‌فرض پورت SSH ایران `22` است. اگر روی ایران SSH روی پورت دیگری ارائه می‌شود، آن
پورت داخل Setup Code منتقل می‌شود.

## نصب

این دستور را روی همان سروری اجرا کنید که می‌خواهید پیکربندی کنید. از فرم صریح `-o`
استفاده می‌شود تا نام فایل خروجی هرگز از مسیر URL ساخته نشود:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o starspeed-tunnel.sh
chmod +x starspeed-tunnel.sh
./starspeed-tunnel.sh
```

روش یک‌خطی جایگزین:

```bash
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o /root/starspeed-tunnel.sh && chmod +x /root/starspeed-tunnel.sh && /root/starspeed-tunnel.sh
```

برای به‌روزرسانی یک نسخه‌ی موجود، به بخش
[به‌روزرسانی](#به‌روزرسانی-update) مراجعه کنید.

## نحوه استفاده (Usage)

اجرای تعاملی منو، و فرمان‌های غیرتعاملی:

```bash
sudo ./starspeed-tunnel.sh            # interactive menu
sudo ./starspeed-tunnel.sh --status   # status only, no changes
sudo ./starspeed-tunnel.sh --setup-code 1
sudo ./starspeed-tunnel.sh --role
sudo ./starspeed-tunnel.sh --version
sudo ./starspeed-tunnel.sh --help     # full option list
```

`--status` فقط گزارش می‌دهد و هیچ تغییری اعمال نمی‌کند. `--setup-code N` کد Setup
مربوط به Foreign شماره‌ی `N` را چاپ می‌کند و `--role` نقش این سرور را
(`iran` / `foreign`) نشان می‌دهد.

## نحوه استفاده از کانفیگ سمت Client

نصب‌کننده **هیچ کانفیگ یا لینکی برای Client تولید نمی‌کند** (هیچ لینک `vless://`،
`vmess://` یا مشابه آن ساخته نمی‌شود). کاری که باید انجام دهید این است:

1. در ایران Setup کنید و برای هر Foreign یک **پورت Frontend** انتخاب کنید.
2. در کانفیگ موجود Client خود، فقط **آدرس و پورت مقصد** را به ایران تغییر دهید:
   * Address = آدرس IP یا نام میزبان سرور ایران
   * Port = پورت Frontend که در ایران انتخاب کرده‌اید
3. سایر فیلدهای کانفیگ (پروتکل، UUID، رمز، TLS و …) را **دست‌نخورده** نگه دارید،
   چون این ابزار آن‌ها را تغییر نمی‌دهد.

چون ترافیک فقط TCP به سمت inbound موجود Xray روی سرور Foreign منتقل می‌شود، از سمت
Client هیچ تفاوتی غیر از آدرس و پورت احساس نخواهد شد.

## راه‌اندازی سرور ایران

اسکریپت را اجرا کنید و گزینه‌ی **`1) Setup Iran`** را انتخاب کنید. ابتدا تعداد
سرورهای Foreign که قرار است از ایران عبور کنند پرسیده می‌شود (۱ یا ۲). سپس برای
هر Foreign از شما این دو مورد پرسیده می‌شود:

* یک پورت Frontend عمومی روی ایران (همان پورتی که Clientها به آن وصل می‌شوند)، و
* پورت inbound مربوط به Xray روی سرور Foreign (هدف Lane).

در ادامه، برای هر Foreign یک بلوک چهار پورت آزاد به‌عنوان Lane تخصیص می‌دهد،
fragmentهای HAProxy را می‌سازد، کانفیگ نامزد را با `haproxy -c` اعتبارسنجی می‌کند، از
کانفیگ فعال نسخه‌ی پشتیبان می‌گیرد و **تنها پس از موفقیت** آن را فعال می‌کند. در پایان
برای هر Foreign یک **Setup Code** چاپ می‌کند.

پورت‌های Lane به‌صورت **اسکن** و از پایه‌ی `46000` با گام `100` تخصیص داده می‌شوند (نه
به‌صورت hard-code)، به این ترتیب که Foreign #1 معمولاً `46101` تا `46104` و Foreign #2
معمولاً `46201` تا `46204` می‌گیرد. اگر پورتی اشغال باشد، کل بلوک کنار گذاشته می‌شود و
بلوک بعدی امتحان می‌گردد؛ یعنی هرگز بخشی از یک بلوک به‌صورت ناقص استفاده نمی‌شود.

Clientهای شما سپس به **پورت Frontend** روی ایران وصل می‌شوند.

## راه‌اندازی Foreign

روی **هر سرور Foreign** اسکریپت را اجرا کنید و گزینه‌ی
**`2) Add / Setup Foreign`** را انتخاب کنید. این موارد را وارد کنید:

* آدرس IP سرور ایران،
* شماره‌ی Foreign که با ایران مطابقت دارد،
* پورت inbound مربوط به Xray که از قبل روی همین سرور وجود دارد،
* Setup Code دریافتی از ایران.

اگر Foreign از قبل پیکربندی شده باشد، ابتدا یک سؤال تأیید می‌پرسد و در صورت
رد کردن، هیچ تغییری اعمال نمی‌شود. اگر پورت inbound چیزی روی آن در حال Listen
نباشد، هشدار می‌دهد و برای ادامه تأیید می‌گیرد.

در سمت Foreign، اسکریپت کارهای زیر را انجام می‌دهد:

* یک جفت‌کلید SSH مخصوص خودش می‌سازد (در صورت وجود کلید سالم، همان را **دوباره
  استفاده** می‌کند و کلید جدید نمی‌سازد)،
* host key ایران را با `ssh-keyscan` در فایل `known_hosts` مخصوص pin می‌کند،
* چهار unit سخت‌گیرانه‌ی `systemd` با نام `starspeed-tunnel-f<N>-lane<M>.service`
  نصب می‌کند.

این unitها هرگز برای رمز عبور منتظر نمی‌مانند و بررسی host key را تضعیف نمی‌کنند:

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

اگر `ssh-keyscan` نتواند host key ایران را بگیرد، اسکریپت خطا می‌دهد و با یک فایل
`known_hosts` خالی ادامه نمی‌دهد.

## اضافه کردن Foreign #2

اگر Foreign #1 از قبل پیکربندی شده باشد، دوباره **`1) Setup Iran`** را اجرا کنید و
تعداد را `2` بگذارید. اسکریپت Foreign #1 را **دست‌نخورده نگه می‌دارد** (پورت‌های
تخصیص‌یافته‌اش را دوباره تخصیص نمی‌دهد و کانفیگش تغییر نمی‌کند) و فقط برای Foreign
جدید موارد لازم را می‌پرسد.

سپس همان مراحل قبلی را برای Foreign #2 روی سرور دوم Foreign تکرار کنید. Foreign #2
پورت Frontend، پورت inbound، بلوک Lane، کلید SSH، `known_hosts` و unitهای کاملاً
مستقلی خواهد داشت.

## فرایند Setup Code و Public Key

**Setup Code** متنی base64 است که فقط شامل تخصیص پورت‌هاست:

```
FOREIGN=<N>
FRONTEND=<port>
INBOUND=<port>
LANE1..LANE4=<ports>
IRAN_SSH_PORT=<port>
IRAN_IP=<ip>          (در صورت وجود)
```

این کد **هیچ رمز عبور یا کلیدی ندارد** و انتقال آن با پیام یا هر کانال دیگری بی‌خطر
است. همچنین اگر Setup Code برای Foreign دیگری باشد و شما شماره‌ی متفاوتی انتخاب
کرده باشید، اسکریپت آن را رد می‌کند و چیزی نمی‌نویسد.

**Public Key**: پس از پایان راه‌اندازی Foreign، اسکریپت روی آن سرور **Public Key** را
چاپ می‌کند. برگردید به ایران، گزینه‌ی **`3) Authorize Foreign Public Key`** را انتخاب
کنید و همان کلید عمومی را وارد کنید تا در `authorized_keys` ایران قرار گیرد.

**Private Key هرگز از سرور Foreign خارج نمی‌شود** و تنها همان‌جا باقی می‌ماند.

## منوی اصلی

| گزینه | نام گزینه در اسکریپت | کار |
| ------ | --------------------- | --- |
| `1` | `Setup Iran` | تخصیص Frontend/Lane و نوشتن کانفیگ HAProxy |
| `2` | `Add / Setup Foreign` | روی سرور Foreign اجرا می‌شود |
| `3` | `Authorize Foreign Public Key` | روی ایران اجرا می‌شود |
| `4` | `Status` | وضعیت Laneها، Frontendها و سلامت HAProxy |
| `5` | `Repair` | بازسازی fragment/unitهای حذف‌شده از روی state ذخیره‌شده |
| `6` | `Remove Foreign` | حذف فقط یک Foreign |
| `7` | `Uninstall` | حذف فقط فایل‌های متعلق به starspeed-tunnel |
| `0` | `Exit` | خروج |

نام گزینه‌ها و شماره‌های بالا دقیقاً همان چیزی است که خود اسکریپت چاپ می‌کند.

## Status

گزینه‌ی **`4) Status`** به‌ازای هر Foreign این موارد را گزارش می‌دهد:

* پورت Frontend روی ایران،
* مقصد Xray (پورت inbound روی سرور Foreign)،
* وضعیت هر چهار Lane (UP یا DOWN)،
* سلامت و فعال بودن HAProxy و معتبر بودن کانفیگ آن.

این خروجی **هیچ اطلاعات محرمانه‌ای** (مانند محتوای Private Key) را چاپ نمی‌کند.
همچنین Setup Code هر Foreign بدون تغییر در state نیز نمایش داده می‌شود.

فرمان‌های غیرتعاملی، مانند `--status` و `--setup-code`، در بخش
[نحوه استفاده](#نحوه-استفاده-usage) فهرست شده‌اند.

## Repair

گزینه‌ی **`5) Repair`** وضعیت ذخیره‌شده، کانفیگ HAProxy، Frontendها، Laneها و
serviceها را بررسی می‌کند:

* اگر fragment یک Foreign حذف شده باشد، از روی state آن را **بازسازی** می‌کند.
* اگر کانفیگ فعال دیگر اعتبارسنجی نشود، آخرین نسخه‌ی پشتیبان معتبر را پیشنهاد
  می‌دهد تا بازیابی شود.
* اگر HAProxy فعال نباشد یا روی Frontend در حال Listen نباشد، برای رفع مشکل تأیید
  می‌گیرد.

اجرای مجدد `Repair` بی‌خطر و idempotent است.

## Remove Foreign

گزینه‌ی **`6) Remove Foreign`** فقط یک Foreign را حذف می‌کند:

* چهار unit مربوط به Laneهای همان Foreign،
* فایل state همان Foreign،
* fragment مربوط به همان Foreign در HAProxy.

سپس اگر روی ایران اجرا شده باشد، کانفیگ HAProxy دوباره ساخته می‌شود، ولی **بقیه‌ی
Foreignها دست‌نخورده باقی می‌مانند**. اگر بازسازی HAProxy شکست بخورد، کانفیگ قبلی
همچنان فعال می‌ماند. انجام این عملیات نیاز به تأیید صریح دارد.

Xray / 3x-ui و هر کانفیگ `Direct` در این فرایند تغییری نمی‌کنند.

## Uninstall

گزینه‌ی **`7` Uninstall** فقط فایل‌هایی را حذف می‌کند که این پروژه ساخته است:

* unitهای Reverse SSH (Laneها) و نسخه‌های پشتیبانشان،
* state ذخیره‌شده و fragmentهای تولیدشده‌ی HAProxy،
* بلوک مدیریت‌شده‌ی include داخل `haproxy.cfg`.

کانفیگ نامرتبط HAProxy و هر چیزی که متعلق به Xray / 3x-ui باشد دست‌نخورده می‌ماند.
جفت‌کلید SSH به‌صورت پیش‌فرض **نگه داشته می‌شود** (در صورت تمایل می‌توانید دستی
حذفش کنید). در پایان یک سؤال پرسیده می‌شود که آیا backupها و logها نیز حذف شوند یا
نه. اگر عملیات را رد کنید، هیچ تغییری اعمال نمی‌شود.

## به‌روزرسانی (Update)

برای بروزرسانی، همان دستور دانلود را دوباره اجرا کنید و مجدد اجرافه بدهید:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/nabilety008/starspeed-tunnel.sh/main/starspeed-tunnel.sh -o starspeed-tunnel.sh
chmod +x starspeed-tunnel.sh
```

در صورت بروزرسانی:

* فایل `starspeed-tunnel.sh` جایگیزن می‌شود، اما هیچ خرابط درست‌ها،
  unit‌ها، fragment‌های HAProxy و setup code‌ها دسته می‌موند، میشم مس‌تودند.
* برای اعمال دوباره بعد از بروزرسانی، ابتدا از `کی‌ن کلید` با نام برای انتقال استفاده نکنید، و اگر می‌خواهید برای برسری ماندی‌تر از `٥) Repair` استفاده کنید.
* برای از اداشتن کانفیگ، هیچ ازس سرور با مجدد مرتبط نکنید، آن‌ها را با سرور ديگر اجرا کنید.

## رفتار Backup و Rollback

* **اعتبارسنجی HAProxy پیش از فعال‌سازی.** کانفیگ نامزد در یک فایل موقت نوشته و با
  `haproxy -c` بررسی می‌شود. اگر ناموفق بود، کانفیگ فعال اصلاً دست‌نخورده می‌ماند و
  نسخه‌ی قبلیِ سالم حفظ می‌شود.
* **Backup پیش از هر بازنویسی.** نسخه‌های قبلی با ذکر زمان در مسیر
  `/etc/starspeed-tunnel/backups` نگه‌داری می‌شوند.
* **حفظ کانفیگ شخصی شما.** فقط یک بلوک مدیریت‌شده‌ی محدودشده نوشته، جایگزین یا حذف
  می‌شود:

  ```
  # >>> starspeed-tunnel managed includes >>>
  ...
  # <<< starspeed-tunnel managed includes <<<
  ```

  هر چیزی خارج از این بلوک متعلق به شماست و اجرای مجدد اسکریپت نتیجه‌ی byte-stable
  می‌دهد (تکرار کردن اسکریپت، فایل را خراب یا پر از خط تکراری نمی‌کند).
* **حذف ناموفق، وضعیت قبلی را نگه می‌دارد.** اگر بازسازی شکست بخورد، اسکریپت صریحاً
  اعلام می‌کند که کانفیگ قبلی همچنان فعال است.

## امنیت (Security)

* **بررسی سخت‌گیرانه‌ی host key همیشه فعال است.** هر Foreign، host key ایران را در
  فایل `known_hosts` مخصوص خودش pin می‌کند. نه `StrictHostKeyChecking=no` و نه
  `accept-new` هرگز استفاده نمی‌شود.
* **Setup Code هیچ اطلاعات محرمانه‌ای ندارد.** فقط متن base64 از تخصیص پورت است.
* **Private Key از Foreign خارج نمی‌شود.** تنها **Public Key** برای ایران ارسال
  می‌شود.
* **فایل‌های state داده هستند، نه کد.** مقادیر پیش از استفاده اعتبارسنجی می‌شوند و
  هرگز `eval` یا به‌عنوان دستور shell اجرا نمی‌شوند؛ بنابراین یک state دست‌کاری‌شده
  نمی‌تواند کد دلخواه اجرا کند.
* **unitها هرگز برای رمز عبور منتظر نمی‌مانند** (`BatchMode=yes`)، پس در
  `boot` یا پس از ری‌استارت، تونل بدون تعامل برقرار می‌شود.
* **`authorized_keys` به‌صورت `0600`** ساخته می‌شود و کلیدهای نامعتبر یا تکراری
  پذیرفته نمی‌شوند.

## فایل‌هایی که مدیریت می‌شوند

```
/etc/starspeed-tunnel/
  state/foreign-N.env        وضعیت ذخیره‌شده هر Foreign
  state/role                 iran | foreign
  haproxy/foreign-N.cfg      fragment مربوط به هر Foreign
  backups/                   نسخه‌های پشتیبان دارای زمان
/etc/systemd/system/starspeed-tunnel-f<N>-lane<M>.service
/root/.ssh/starspeed-tunnel_f<N>        کلید خصوصی (فقط روی Foreign)
/root/.ssh/starspeed-tunnel_f<N>.pub    کلید عمومی (فقط روی Foreign)
/root/.ssh/starspeed-tunnel_iran<N>    host key پین‌شده‌ی ایران (فقط روی Foreign)
```

## محدودیت‌ها (Limitations)

* از **یک سرور ایران** و **حداکثر دو سرور Foreign** پشتیبانی می‌شود (منو فقط `1` یا
  `2` را می‌پذیرد).
* فقط **TCP** منتقل می‌شود؛ پروتکل‌های UDP-based پشتیبانی نمی‌شوند.
* این ابزار جایگزین Xray یا 3x-ui نیست؛ فقط یک مسیر شبکه‌ی پایدار فراهم می‌کند.
* هدف: Ubuntu 22.04 / 24.04 با `systemd`.
* این ابزار **هیچ قابلیتی برای fake upload، تولید ترافیک معکوس، iperf یا «آپلود ۱ درصد»
  ندارد**؛ چنین چیزی پیاده‌سازی نشده است.
* فقط **یک inbound موجود** در هر Foreign هدف قرار می‌گیرد.

## تست (Testing)

مجموعه‌ی تست به‌طور کامل در محیط‌های موقت (sandbox) با نسخه‌های ساختگی `systemctl`،
`ss`، `haproxy` و `ssh-keyscan` اجرا می‌شود. این تست‌ها هرگز به `/etc` واقعی، systemd
واقعی، HAProxy واقعی، شبکه یا SSH واقعی دست نمی‌زنند.

```bash
bash tests/run-tests.sh          # everything
bash tests/run-tests.sh unit     # validation/allocation/state only
bash tests/syntax-check.sh       # bash -n over every shell file
```

تست‌ها جریان‌های زیر را پوشش می‌دهند: راه‌اندازی ایران، اجرای مجدد و
idempotency، اضافه کردن Foreign #2 بدون دست‌زدن به #1، راه‌اندازی سمت Foreign،
authorize کردن کلید، Status، Repair، حذف یک Foreign، Uninstall، و rollback در
حالتی که `haproxy -c` شکست بخورد.

## عیب‌یابی (Troubleshooting)

ابتدا **`4) Status`** را اجرا کنید. این دستور به‌ازای هر Foreign، Frontend، مقصد Xray،
وضعیت هر Lane و سلامت HAProxy را بدون چاپ هیچ اطلاعات محرمانه‌ای گزارش می‌دهد.

اگر HAProxy بالا نمی‌آید، کانفیگ را دستی اعتبارسنجی کنید:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
```

موارد رایج:

* **`nothing is listening on 127.0.0.1:<port>`** — inbound مربوط به Xray روی سرور
  Foreign وجود ندارد یا Listen نیست. آن را در Xray/3x-ui خودتان بررسی کنید (این ابزار
  آن را تغییر نمی‌دهد).
* **`Lane N: DOWN`** — روی سرور Foreign، سرویس مربوطه فعال نیست یا اتصال SSH برقرار
  نشده است:

  ```bash
  sudo systemctl status starspeed-tunnel-f1-lane1.service
  ```

* **`the live HAProxy configuration does not validate`** — با گزینه‌ی
  **`5) Repair`** آخرین backup معتبر را بازیابی کنید، یا fragment خراب شده را اصلاح
  کنید.
* **`host key not pinned`** — مطمئن شوید `ssh-keyscan` از سرور Foreign به ایران
  دسترسی دارد (پورت SSH و فایروال را بررسی کنید). ادامه دادن با یک `known_hosts`
  خالی عمداً مجاز نیست.
* **ارتباط SSH قطع می‌شود** — `ServerAliveInterval=15` و `ServerAliveCountMax=3`
  تنظیم شده‌اند؛ اگر قطعی‌های مکرر دارید، مسیر شبکه یا کیفیت لینک را بررسی کنید.

## ❤️ حمایت از starspeed-tunnel

اگر starspeed-tunnel برای شما مفید بوده و مایلید از ادامه توسعه آن حمایت کنید،
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

## لایسنس (License)

این پروژه تحت لایسنس MIT منتشر می‌شود. متن کامل در [LICENSE](LICENSE).
