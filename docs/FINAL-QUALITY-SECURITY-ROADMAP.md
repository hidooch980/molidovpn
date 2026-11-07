# برنامه نهایی کیفیت، امنیت و تکمیل MolidoVPN

> **کیفیت در هر خط؛ امنیت در هر اتصال؛ طراحی برای همه؛ رضایت با صداقت.**

- تاریخ تدوین: 2026-11-07
- وضعیت: برنامه اجرایی و معیار پذیرش؛ نه گواهی آماده‌بودن محصول
- دامنه: Android، Windows، منابع سرور، پروتکل‌ها، اتصال هوشمند، امنیت، حریم خصوصی، UX، زیرساخت و انتشار

## 1. هدف و تعریف «نهایی»

هدف، ساخت محصولی پایدار و قابل‌اعتماد برای شبکه‌های متغیر و محدود ایران است. «بدون خطا و باگ» تضمین مطلق‌پذیر نیست؛ معیار قابل‌قبول این است که هیچ نقص بحرانی شناخته‌شده‌ای باز نماند، هر قابلیت آزمون و شواهد قابل‌ردیابی داشته باشد، خرابی‌ها امن و قابل‌بازیابی باشند و محدودیت‌های آزمایش‌نشده صادقانه اعلام شوند.

هیچ سرور عمومی، نتیجهٔ پینگ، موفقیت handshake یا تست یک VPS به‌تنهایی اثبات‌کنندهٔ تونل سالم، حریم خصوصی یا کیفیت در سراسر ایران نیست.

## 2. اصول غیرقابل‌مذاکره

1. **امنیت مقدم بر اتصال:** در شکست اعتبارسنجی، گواهی، امضا، DNS policy یا کنترل نشت، مسیر ناامن به‌عنوان fallback انتخاب نشود.
2. **وضعیت صادقانه:** تفاوت بین آماده‌سازی، اتصال، انتقال واقعی داده، اتصال محدود، قطع و خطای امنیتی در UI روشن باشد.
3. **تفکیک نوع تونل:** Proxy، DNS-only، split tunnel و full-device VPN هرگز با یک برچسب نمایش داده نشوند.
4. **منبع قابل‌ردیابی:** هر پروفایل باید منبع، زمان دریافت، زمان آخرین آزمون، مجوز/شرایط استفاده و سطح اعتماد داشته باشد.
5. **کمینه‌سازی داده:** IP دقیق، محتوای ترافیک، DNS query، SSID/BSSID، شماره تلفن و شناسه‌های غیرضروری جمع‌آوری نشوند.
6. **مهاجرت تدریجی:** هیچ مسیر فعال یا زنجیرهٔ انتشار بدون جایگزین آزموده‌شده حذف نشود.
7. **AI محدود و قابل‌کنترل:** هوش مصنوعی فقط پیشنهاددهندهٔ رتبه‌بندی باشد؛ حق تغییر trust roots، گواهی‌ها، سیاست DNS، Kill Switch، امضا یا محدودیت‌های امنیتی را ندارد.
8. **قابلیت لغو و بازیابی:** به‌روزرسانی، تنظیمات، اتصال و جمع‌آوری telemetry باید قابل‌لغو و قابل‌بازیابی باشند.

## 3. معماری مقصد

- **Presentation:** رابط فارسی‌محور RTL، ساده و پیشرفته، دسترس‌پذیر و قابل استفاده با صفحه‌خوان.
- **Application orchestration:** ماشین حالت اتصال، cancellation، timeout، retry محدود، reconnect و failover با جلوگیری از race condition.
- **Domain contracts:** مدل مستقل از UI برای Provider، Profile، Protocol، TunnelMode، Evidence، HealthSample، TrustTier و ConnectionState.
- **Provider adapters:** دریافت فهرست‌ها و اشتراک‌ها از طریق آداپتورهای جدا، parserهای محدود و نسخه‌بندی‌شده.
- **Validation pipeline:** schema validation، allowlist پروتکل‌ها، محدودیت اندازه، URL scheme، host/port، credential handling، deduplication و provenance.
- **Quality engine:** دادهٔ اندازه‌گیری‌شده، تازگی، latency، loss، throughput، stability و شواهد امنیتی را جدا نگه دارد.
- **Platform adapters:** Android VpnService/TUN و Windows native VPN/proxy/TUN با قابلیت‌های اعلام‌شدهٔ دقیق.
- **Observability:** گزارش‌های حداقلی، opt-in، scrubbed و دارای retention/deletion روشن.
- **Release engineering:** build reproducible تا حد امکان، امضا، SHA-256، provenance، SBOM، تست نصب/ارتقا و rollback.

## 4. منابع سرور و سرویس‌ها

### 4.1 طبقه‌بندی اعتماد

| سطح | نوع منبع | سیاست |
|---|---|---|
| A — مدیریت‌شده | سرورهای متعلق به Molido یا ارائه‌دهندهٔ قراردادی با API احراز هویت‌شده | اولویت بالاتر؛ مالکیت، مجوز، SLA، کلیدها و سلامت باید قابل‌اثبات باشد |
| B — رسمی/جامعه‌ای شناخته‌شده | پروژه‌هایی مانند VPN Gate یا استقرارهای عمومی eduVPN | عمومی و کم‌اعتمادتر؛ رضایت/شرایط استفاده، عمر کوتاه و هشدار حریم خصوصی |
| C — تجمیع‌گرها و فهرست‌های ثالث | فیدهای عمومی و لیست‌های community | ورودی غیرقابل‌اعتماد؛ قرنطینه تا parse، اعتبارسنجی و آزمون مستقل |
| D — واردشده توسط کاربر | URL اشتراک، فایل، QR، clipboard و پروفایل دستی | رضایت صریح، نمایش منبع و دامنهٔ دسترسی، ذخیره‌سازی امن اسرار |

**هیچ منبع عمومی یا تجمیع‌گر ناشناخته‌ای به‌صورت پیش‌فرض Tier A نمی‌شود.** وجود یک نام یا URL در فهرست به معنی مجوز استفاده، امن بودن یا کارکرد در ایران نیست.

### 4.2 کاندیداهای بررسی‌شونده

- VPN Gate: فهرست رله‌های داوطلبانه و متغیر؛ صرفاً منبع کشف/آزمایش با هشدار روشن، نه سرور قابل‌اعتماد برای ترافیک حساس.
- eduVPN/LEAP: بررسی استقرارهای رسمی و شرایط استفاده؛ وجود نرم‌افزار یا پروژه به معنی وجود سرور عمومی رایگان نیست.
- OpenVPN Access Server API: فقط برای سرورهای تحت مالکیت یا مجوزدار و با توکن امن.
- پنل‌های مدیریت چندنودی مانند NX Panel: فقط پس از بررسی امنیت، مجوز، نگهداری و سازگاری؛ خود پنل را با تأمین‌کنندهٔ سرور اشتباه نگیریم.
- فهرست‌های تجمیعی عمومی: صرفاً discovery و با قرنطینه، rate limit، provenance و حذف خودکار دادهٔ منقضی.
- اشتراک‌های خصوصی: پشتیبانی از import با رضایت کاربر، بدون ارسال credential به telemetry یا commit.

برای هر adapter باید این موارد ثبت شوند: مالک/اپراتور، URL رسمی، مجوز و شرایط، پروتکل/فرمت، احراز هویت، rate limit، سقف پاسخ، schema version، تناوب refresh، TTL، attribution، کلیدها، سیاست حذف، آزمون parser و سلامت. در صورت نبود شواهد حقوقی/فنی، adapter غیرفعال می‌ماند.

### 4.3 چرخهٔ ورود منبع

1. دریافت محدود و زمان‌دار از endpoint مجاز.
2. بررسی TLS و host allowlist؛ جلوگیری از SSRF و redirect به شبکه‌های خصوصی/metadata.
3. سقف اندازه و تعداد رکورد، parse در sandbox منطقی و رد ورودی malformed.
4. canonicalization و deduplication بدون افشای credential.
5. برچسب provenance و trust tier.
6. آزمون سلامت در سطح پروتکل و سپس آزمون انتقال داده از دستگاه.
7. انتشار فقط پس از عبور از gate؛ رکوردهای مشکوک در quarantine.
8. انقضا و حذف خودکار بر اساس TTL؛ امکان blocklist و گزارش سوءاستفاده.

## 5. پروتکل‌ها و سازگاری پلتفرم

پشتیبانی پروتکل باید در ماتریس capability به تفکیک Android/Windows و نوع تونل ثبت شود. وجود parser یا import به معنی اجرای native یا full tunnel نیست.

کاندیداهای ماتریس: IKEv2/IPsec، WireGuard، OpenVPN، AmneziaWG، VLESS/Reality، VMess، Trojan، Shadowsocks، Hysteria2، TUIC، AnyTLS، SOCKS، Psiphon، Tor، MASQUE و SoftEther.

برای هر پروتکل چهار وضعیت مجزا لازم است: **Import/Parse، Handshake، Data-plane، Security/Leak verification**. فقط پس از عبور از هر چهار مرحله می‌توان آن را «تأییدشده برای انتشار» نامید.

- Android: سازگاری نسخه API، VpnService، چرخهٔ حیات، foreground service، battery optimization، ABI، native libraries و مجوز VPN.
- Windows: x64، Windows 10/11، driver/runtime، native VPN profile، proxy/TUN mode، service lifecycle، elevation، firewall و uninstall cleanup.
- IKEv2: اعتبارسنجی هویت سرور و گواهی؛ credential هر provider نباید به provider دیگر نشت کند. failover خودکار فقط بعد از اثبات رفتار امن credential و reconnect.
- هر capability فاقد پیاده‌سازی یا تست واقعی با برچسب «آزمایشی/پشتیبانی‌نشده» باقی بماند.

## 6. One-Tap Smart Connect و کیفیت

ماشین حالت واحد و قابل‌آزمون تعریف شود:

idle → discovering → validating → connecting → verifying_data → connected

حالت‌های جانبی: degraded، cancelling، reconnecting، blocked_security و failed.

قواعد:
- پیش از قطع اتصال فعلی، candidate جدید اعتبارسنجی شود؛ مگر خرابی فعلی خطر امنیتی ایجاد کند.
- هر تلاش timeout و cancellation قطعی داشته باشد.
- retry محدود، backoff و circuit breaker برای جلوگیری از حلقهٔ بی‌پایان.
- failover با hysteresis؛ نوسان کوچک latency باعث تعویض مکرر نشود.
- کیفیت و امنیت دو امتیاز مستقل‌اند؛ کیفیت بالا هرگز شکست امنیت را جبران نمی‌کند.
- نمونهٔ stale، future-dated، ناقص، تخمینی یا خارج از محدوده برای رتبه‌بندی زنده رد شود.
- اتصال موفق فقط با handshake اعلام نشود؛ انتقال دادهٔ واقعی و آزمون مسیر لازم است.
- انتخاب کشور خروج تا زمان مشاهدهٔ IP خروج و تأیید مستقل، «ترجیح کشور» باشد نه تضمین.

### سیگنال‌های رتبه‌بندی

Latency، jitter، packet loss، throughput، زمان برقراری، پایداری در بازهٔ زمانی، موفقیت انتقال داده، نوع شبکه، تازگی نمونه و هزینهٔ باتری. وزن‌ها باید نسخه‌بندی و با دادهٔ واقعی ارزیابی شوند؛ unknown به معنی صفر یا عالی نیست.

## 7. امنیت و حریم خصوصی

- مدیریت secrets با Android Keystore/Windows Credential Manager یا مخزن امن متناسب؛ عدم ذخیرهٔ رمز در log، command-line یا plaintext preferences.
- TLS validation، certificate/identity verification و امضای artifact؛ هیچ حالت insecure برای «وصل شدن به هر قیمت» مجاز نیست.
- Kill Switch و DNS policy فقط وقتی ادعا شوند که روی دستگاه و مسیر واقعی تست شده‌اند.
- آزمون DNS، IPv4، IPv6، WebRTC در صورت مرتبط بودن، route leak و قطع ناگهانی tunnel.
- محدودیت permission، sandbox، secure defaults و حذف دادهٔ موقت.
- telemetry فقط opt-in، با توضیح دقیق داده‌ها، امکان لغو، retention و حذف.
- شناسهٔ نصب پایدار فقط در صورت ضرورت مستند و با کنترل کاربر.
- dependency scanning، secret scanning، SAST، SBOM و بررسی مجوز وابستگی‌ها.
- مدل تهدید برای provider مخرب، config مخرب، DNS manipulation، captive portal، downgrade، replay، update tampering و supply-chain attack.

## 8. UX، طراحی و دسترس‌پذیری

- صفحهٔ اصلی خلوت: وضعیت واقعی، یک دکمهٔ اتصال/قطع، نام مسیر، کشور تأییدشده یا نامشخص، و توضیح کوتاه کیفیت.
- جزئیات فنی در بخش پیشرفته؛ نام پروتکل‌ها و منابع نباید کاربر عادی را سردرگم کند.
- حالت‌های روشن/تاریک، RTL واقعی، فارسی/انگلیسی/عربی/ترکی، فونت خوانا و اندازهٔ متن پویا.
- وضعیت‌های loading/empty/error/offline/permission denied با راهنمای عملی.
- انیمیشن کم‌مصرف و قابل‌کاهش؛ رنگ تنها راه انتقال وضعیت نباشد.
- کنترل‌های بزرگ، کنتراست، صفحه‌خوان و تست اندازه‌های مختلف صفحه.
- نمایش هشدار مناسب برای سرور عمومی و جلوگیری از القای امنیت/ناشناس‌بودن تضمین‌شده.

## 9. پایداری و مصرف منابع

- timeout و سقف concurrency برای probeها؛ اسکن پس‌زمینه فقط در شرایط مجاز و با محدودیت باتری/داده.
- cache با TTL و fallback به آخرین دادهٔ معتبر، نه آخرین دادهٔ دلخواه.
- مدیریت حافظه و native resource؛ جلوگیری از orphan process، file descriptor leak و tunnel zombie.
- تست شبکهٔ قطع‌و‌وصل، تغییر Wi-Fi/mobile، sleep/resume، reboot و کمبود حافظه.
- عدم اجرای probeهای حجیم روی شبکهٔ محدود یا بدون رضایت.
- لاگ ساختاریافته با redaction و سقف حجم؛ بدون ثبت config کامل یا secret.

## 10. به‌روزرسانی و زنجیرهٔ انتشار

- زنجیرهٔ canonical source برای Android و Windows باید با workflow و artifact واقعی مستند و بدون تعارض باشد.
- هر artifact: tag، commit SHA، version، signer fingerprint، SHA-256، SBOM و provenance.
- updater فقط metadata و host مورد اعتماد را قبول کند؛ hash، اندازه، tag و امضا را قبل از نصب بررسی کند.
- دانلود resumable و محدود؛ فایل ناقص/corrupt پاک شود.
- Android: نصب از package installer رسمی و رضایت کاربر؛ حفظ نسخهٔ قبلی تا تکمیل نصب.
- Windows: امضای Authenticode در صورت دسترسی به گواهی معتبر، بررسی hash، نصب/حذف تمیز و rollback.
- staged rollout، توقف انتشار در صورت افزایش crash/rollback و release notes با محدودیت‌های شناخته‌شده.
- secretهای signing فقط در secret store؛ هرگز در repo یا artifact عمومی.

## 11. ماتریس تست و معیار پذیرش

### خودکار در هر Pull Request
- format/lint/static analysis و type checks.
- unit tests برای parser، state machine، scoring، trust policy، retry و cancellation.
- fuzz/property tests برای parserهای config و ورودی‌های نامعتبر.
- dependency/license/secret scan و SAST.
- build Android و Windows و بررسی manifest، ABI، package، version و artifact.
- تست regression و snapshot برای UI حیاتی.

### ادغام و انتشار
- نصب تمیز، ارتقا از نسخهٔ قبلی، downgrade policy، rollback و uninstall.
- Android واقعی: VPN consent، پس‌زمینه، battery saver، Wi-Fi/mobile handover، DNS و IPv4/IPv6 leak، Kill Switch.
- Windows واقعی: proxy/TUN، DNS، firewall، sleep/resume، crash recovery، uninstall و rollback.
- تست هر پروتکل با endpoint تحت کنترل و ثبت data-plane، نه صرفاً parser/handshake.
- ماتریس ایران در صورت دسترسی: همراه اول، ایرانسل، رایتل، ISP ثابت/FWA، چند منطقه و زمان؛ IPv4/dual-stack/IPv6، MTU، packet loss، congestion و captive portal.
- هیچ نتیجهٔ یک اپراتور یا VPS به همهٔ کاربران تعمیم داده نشود.

### شدت ایراد
- **P0:** نشت داده/credential، دور زدن policy امنیتی، نصب artifact دستکاری‌شده، خرابی گسترده یا اتصال ناامن. انتشار ممنوع.
- **P1:** crash، اتصال ناپایدار گسترده، از کار افتادن updater یا پاک‌نشدن route/proxy. انتشار عمومی متوقف تا رفع.
- **P2:** نقص عملکردی محدود یا UX مهم با workaround. باید پیش از release پایدار رفع یا محدودیت آن شفاف شود.
- **P3:** جزئیات ظاهری/کم‌اثر. در backlog با اولویت ثبت شود.

## 12. ترتیب اجرای پیشنهادی

### فاز 0 — تثبیت واقعیت
- تعیین source of truth Android و Windows با workflow، commit و checksum.
- فهرست کردن همهٔ adapterها، منابع، پروتکل‌ها، feature flags و محدودیت‌های واقعی.
- بررسی PRهای باز، CI، workflowها، updater و release assets؛ عدم تداخل branchها.

### فاز 1 — ایمنی پایه
- تکمیل quality/security gates و اتصال آن‌ها به مسیر واقعی انتخاب سرور.
- privacy review، credential handling، Kill Switch/DNS claims و مدل تهدید.
- بستن P0/P1 و افزودن regression tests.

### فاز 2 — منابع و پروتکل‌ها
- تعریف provider contract و provenance.
- یک adapter کم‌ریسک و مجاز را ابتدا در حالت discovery-only اضافه کن.
- پس از تست parser و شرایط استفاده، data-plane را به‌صورت feature flag و staged rollout فعال کن.
- منابع عمومی از منابع اختصاصی جدا و هشداردهی شوند.

### فاز 3 — Smart Connect
- یکپارچه‌سازی ماشین حالت، quality scoring، security gate، cancellation و failover.
- اثبات اینکه اتصال جایگزین قبل از قطع مسیر سالم آماده است.
- عدم فعال‌سازی خودکار برای پروتکل‌های فاقد credential-safe failover.

### فاز 4 — تجربه و پایداری
- اصلاح UX، زبان‌ها، دسترس‌پذیری، گزارش خطا و مصرف منابع.
- تست‌های طولانی‌مدت، handover و recovery.

### فاز 5 — انتشار کنترل‌شده
- build reproducibility، امضا، SBOM، hash، updater و rollback.
- انتشار آزمایشی، پایش، سپس انتشار عمومی تنها پس از عبور همهٔ gateها.
- مستندسازی تست‌های واقعی و موارد تست‌نشده.

## 13. وضعیت فعلی و محدودیت‌های شناخته‌شده

این سند برنامه و معیار پذیرش است. به‌تنهایی هیچ کدی را تغییر نمی‌دهد و هیچ تستی را اجرا نمی‌کند.

در بررسی قبلی زنجیرهٔ انتشار، workflow مخزن hidooch980/molidovpn-android مسئول build/sign APKهای native بوده و مخزن اصلی APKها را mirror/validate می‌کرد؛ Windows از مخزن اصلی build می‌شد. تا اثبات انتقال کامل و برابری artifactها، مخزن Android جداگانه نباید حذف یا archive شود.

PRهای مرتبط کیفیت/معماری قبلاً باز بوده‌اند؛ پیش از ادغام باید head و CI تازهٔ آن‌ها بررسی شود. quality engine به‌تنهایی تا زمان اتصال به orchestration، تضمین‌کنندهٔ رتبه‌بندی زنده یا جلوگیری از اتصال ناامن نیست.

تست واقعی روی دستگاه Android، Windows واقعی و شبکه‌های اپراتورهای ایران باید جداگانه ثبت شود. CI سبز جایگزین این آزمون‌ها نیست.

## 14. Definition of Done

یک نسخه فقط زمانی «آمادهٔ انتشار پایدار» است که:
- source of truth و زنجیرهٔ build قابل‌ردیابی باشند.
- تمام قابلیت‌های تبلیغ‌شده در ماتریس capability شواهد داشته باشند.
- هیچ P0/P1 باز نباشد.
- CI روی commit دقیق release سبز باشد.
- تست‌های دستگاه و شبکهٔ واقعی در دامنهٔ اعلام‌شده پاس شده باشند.
- leak/security/privacy review بسته شده باشد.
- updater، امضا، hash، نصب، ارتقا و rollback تأیید شده باشند.
- release notes محدودیت‌ها را پنهان نکنند.
- برنامهٔ rollback و توقف انتشار آماده باشد.

**نتیجه:** اول صحت و امنیت، سپس کیفیت اتصال، بعد گستردگی منابع و پروتکل‌ها، و در پایان انتشار. هیچ feature count یا ادعای بازاریابی نباید این ترتیب را معکوس کند.
