# MolidoVPN Next — ممیزی پایه معماری

> شعار اجرایی: **کیفیت در هر خط؛ امنیت در هر اتصال؛ طراحی برای همه؛ رضایت با صداقت.**

این سند، ممیزی اولیه بر اساس فایل‌های شاخهٔ `main` در تاریخ 2026-11-07 است. این سند ادعای ممیزی کامل کد یا اجرای تست ندارد.

## 1) یافتهٔ مهم: تعارض در منبع اصلی Android

در `README.md` گفته شده مخزن `hidooch980/molidovpn` مرجع یکپارچه است و `android-app/` کلاینت بومی Android محسوب می‌شود؛ مخزن `hidooch980/molidovpn-android` آینهٔ سازگاری/انتشار قبلی معرفی شده است.

اما `docs/ARCHITECTURE.md` می‌گوید کلاینت native Android (Kotlin + Rust) در مخزن جداگانهٔ `hidooch980/molidovpn-android` قرار دارد و APKهای انتشار از مخزن اصلی ساخته می‌شوند. همچنین `pubspec.yaml` ریشه، Flutter را تعریف می‌کند.

**تصمیم ایمن:** تا زمانی که workflow انتشار، مسیر build، commit و checksum خروجی APK و برابری/اختلاف کد دو مسیر بررسی نشده، هیچ‌کدام را به‌صورت خودکار canonical اعلام یا حذف نمی‌کنیم. این یک مانع P0 برای هر بازآرایی Android است.

## 2) نقشهٔ فعلی مشاهده‌شده

- ریشهٔ مخزن: برنامه Flutter، منطق مشترک، Windows، سایت، Cloudflare Worker، پنل، ابزارها و workflowها.
- `android-app/`: طبق README، کد native Android و اجزای Kotlin/Rust؛ باید با workflow واقعی تطبیق داده شود.
- مخزن `molidovpn-android`: طبق سند معماری، کلاینت native و مسیرهای release/core update؛ وضعیت دقیق همگامی باید بررسی شود.
- `vpn-sub`: گردآوری و اسکن منابع سرور؛ خروجی‌های اشتراک.
- Cloudflare Worker: توزیع اشتراک، گزارش‌ها، flags و پنل مدیریت.

## 3) معماری مقصد پیشنهادی

1. **Presentation:** UI ساده و فارسی‌محور، RTL، دسترس‌پذیری و وضعیت اتصال صادقانه.
2. **Application:** orchestration اتصال، cancellation، timeout، retry محدود، reconnect و failover بدون race.
3. **Domain:** قراردادهای مستقل از UI برای سرور، مسیر، سنجه، وضعیت و سیاست امنیتی.
4. **Data & Providers:** آداپتورهای منابع، اعتبارسنجی ورودی، deduplication، cache با TTL و اولویت منبع.
5. **Platform adapters:** مسیرهای مستقل Android VpnService/TUN و Windows proxy/TUN/native VPN؛ نوع مسیر همیشه در مدل و UI مشخص باشد.
6. **Quality & Observability:** منشأ، زمان و اعتبار سنجه‌ها؛ عدم امتیازدهی به دادهٔ تخمینی/کهنه.
7. **Security & Privacy:** شواهد pass/fail/unknown، fail-closed در سیاست‌های سخت‌گیرانه، کمینه‌سازی داده و رضایت قابل‌لغو.
8. **Release engineering:** امضای artifact، SHA-256، provenance، SBOM، تست نصب/ارتقا و rollback.

## 4) قواعد مهاجرت

- بازنویسی یک‌باره ممنوع؛ مهاجرت تدریجی با adapter و تست سازگاری.
- ابتدا قرارداد و تست؛ سپس جابه‌جایی کد.
- مسیر پایدار موجود تا اثبات جایگزین، حذف نمی‌شود.
- کلیدها، توکن‌ها، گواهی‌ها و دادهٔ حساس وارد Git یا log نمی‌شوند.
- هیچ fallback امنیتی نباید به اتصال مستقیمِ ناخواسته منجر شود.
- proxy-only هرگز به‌عنوان full-device VPN نمایش داده نمی‌شود.
- IKEv2 و سایر مسیرهای بدون handshake و تست leak واقعی، آزمایشی باقی می‌مانند.

## 5) معیارهای ایران

تست باید به تفکیک اپراتور/نوع دسترسی و زمان انجام شود: همراه اول، ایرانسل، رایتل و ISPهای ثابت/FWA در صورت دسترسی. سناریوها شامل IPv4، dual-stack/IPv6 در صورت پشتیبانی، DNS خراب، captive portal، packet loss، RTT بالا، MTU، جابه‌جایی Wi-Fi/mobile، پس‌زمینه و sleep/resume است.

فقط دادهٔ حداقلی و با رضایت کاربر ثبت شود. IP دقیق، شماره سیم‌کارت، SSID/BSSID، DNS query، مقصد وب‌گردی و محتوای ترافیک جمع‌آوری نشود.

## 6) دروازه‌های انتشار

- [ ] منبع اصلی Android و زنجیرهٔ تولید APK با شواهد مشخص شد.
- [ ] قراردادهای Domain و state machine مستند و تست شدند.
- [ ] تست‌های unit/integration و CI روی commit دقیق release سبز هستند.
- [ ] DNS، IPv4/IPv6، Kill Switch و قطع تونل روی دستگاه واقعی تست شده‌اند.
- [ ] Windows proxy/TUN، بازیابی proxy و sleep/resume روی Windows واقعی تست شده‌اند.
- [ ] ماتریس چندشبکه‌ای ایران با نتایج و محدودیت‌های واقعی ثبت شده است.
- [ ] privacy review، رضایت، نگهداری/حذف داده و redaction تأیید شده است.
- [ ] امضا، checksum، ارتقا و rollback artifact بررسی شده است.
- [ ] هیچ ایراد P0 باز نیست و release notes محدودیت‌ها را شفاف می‌گویند.

## 7) گام بعدی

ابتدا workflowهای release هر دو مخزن، مسیرهای build Android، فایل‌های manifest/Gradle و تست‌های موجود را تطبیق می‌دهیم. پس از تعیین source of truth، اولین ماژول قابل‌جداسازی را انتخاب می‌کنیم. این سند به‌تنهایی به معنی تغییر کد اجرایی، اجرای تست، ادغام یا انتشار نیست.


## 8) نتیجهٔ بررسی زنجیرهٔ انتشار Android و Windows

بررسی فایل‌های واقعی workflow و Gradle در دو مخزن، تصویر روشن‌تری از مسیر فعلی می‌دهد:

### Android — منبع build واقعی

- در مخزن `hidooch980/molidovpn-android`، فایل `.github/workflows/release.yml` مستقیماً پروژهٔ Gradle را checkout می‌کند، Rust core را برای ABIهای Android می‌سازد، keystore را از GitHub Secrets دریافت می‌کند، APKهای mobile و TV را build و امضا می‌کند، package/version/signer را اعتبارسنجی می‌کند و Release را در همان مخزن منتشر می‌کند.
- فایل `app/build.gradle.kts` همین مخزن، شناسهٔ برنامه `com.mobin.mobin_vpn`، حداقل API 26، target SDK 36، ABIهای ARM و نسخه‌گذاری build را تعریف می‌کند.
- در مخزن اصلی `hidooch980/molidovpn`، workflow ریشه در job با نام `android`، APKها را از Release مخزن `molidovpn-android` دانلود می‌کند؛ آن‌ها را بررسی و با نام‌های MolidoVPN/MobInVPN کپی می‌کند. بنابراین این job در وضعیت فعلی **APK بومی Android را از سورس ریشه build نمی‌کند**؛ نقش آن mirror/verification است.
- همان workflow ریشه، Windows را از checkout مخزن اصلی با `flutter build windows --release` می‌سازد و هسته‌ها/وابستگی‌های Windows را bundle می‌کند.

**نتیجهٔ مستند:** زنجیرهٔ تولید و امضای APKهای منتشرشده در workflow بررسی‌شده، در حال حاضر به مخزن `molidovpn-android` وابسته است. مخزن اصلی نقش هماهنگ‌کنندهٔ انتشار یکپارچه، mirror کردن APKها و ساخت Windows را دارد. این با برداشت «Android native در android-app مخزن اصلی build می‌شود» سازگار نیست. پس تا زمان انتقال کنترل‌شده و اثبات برابری artifactها، مخزن Android جداگانه را نباید archive یا حذف کرد.

### نکات مثبت مشاهده‌شده

- انتشار Android به tag نسخه‌ای و نیز مسیرهای کنترل‌شدهٔ workflow متصل است.
- workflow Android امضای APK، package ID، versionCode، نسخهٔ نامی، SHA-256 و چند ABI را بررسی می‌کند.
- workflow ریشه هنگام mirror کردن، تطبیق tag نسخه و امضای APK و عدم کاهش versionCode را کنترل می‌کند.
- build ویندوز در مخزن اصلی انجام می‌شود و نسخهٔ آن از نسخهٔ Android انتخاب‌شده در workflow گرفته می‌شود.

### مواردی که هنوز اثبات نشده‌اند / ریسک‌های باز

- وجود کد یا workflow در `android-app/` مخزن اصلی به‌تنهایی ثابت نمی‌کند که همان کد، APK منتشرشده را تولید می‌کند؛ باید dependency graph، تاریخچهٔ انتقال و تطبیق source-to-artifact بررسی شود.
- emulator smoke test، حتی اگر در CI موفق باشد، جایگزین نصب/ارتقای واقعی روی گوشی، آزمون VPN permission، DNS/IPv6 leak، Kill Switch و جابه‌جایی شبکه نیست.
- از روی workflow نمی‌توان سلامت واقعی شبکه در ایران یا عملکرد همهٔ اپراتورها را نتیجه گرفت.
- تست Windows روی runner ویندوزی، جایگزین آزمون روی Windows واقعی با proxy/TUN، sleep/resume، قطع اجباری و uninstall/rollback نیست.
- باید workflowهای دقیق مربوط به updater، installer، امضای Windows، feedها و rollback جداگانه بررسی شوند؛ این ممیزی هنوز آن‌ها را تأیید نکرده است.

## 9) اقدام بعدی مصوب پیشنهادی

1. **تثبیت نقشهٔ انتشار:** README و اسناد معماری را با واقعیت workflowها هماهنگ کنیم؛ بدون تغییر رفتار انتشار.
2. **مقایسهٔ کد Android:** درخت فایل‌ها، packageها، Gradle، Kotlin، Rust، manifestها و تاریخچهٔ انتقال بین `android-app/` و مخزن جداگانه را تطبیق دهیم.
3. **تطبیق artifact:** یک نسخهٔ مشخص را با commit SHA، tag، versionCode، signer fingerprint و SHA-256 دنبال کنیم تا زنجیرهٔ سورس تا APK قابل‌ردیابی شود.
4. **ممیزی Windows:** workflowهای installer، updater، امضا، hash، rollback و تفاوت proxy/TUN را جداگانه بررسی کنیم.
5. **اولین تغییر اجرایی:** فقط پس از این شواهد، کوچک‌ترین ماژول مستقل و کم‌ریسک را با تست و PR جداگانه پیاده کنیم.

هیچ‌یک از این یافته‌ها به معنی موفقیت تست جدید، تأیید امنیت کامل، ادغام PR یا انتشار نسخه نیست.
