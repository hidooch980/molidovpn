<div dir="rtl">

# MolidoVPN

**یک VPN رایگان و ساده برای خانواده‌های ایرانی — اندروید، ویندوز و آیفون.**

[![Release](https://img.shields.io/github/v/release/hidooch980/molidovpn?style=flat-square)](https://github.com/hidooch980/molidovpn/releases/latest)
[![Telegram](https://img.shields.io/badge/Telegram-@Molido__Vpn-26A5E4?style=flat-square&logo=telegram)](https://t.me/Molido_Vpn)

[سایت](https://hidooch980.github.io/molidovpn/) · [دانلود](https://github.com/hidooch980/molidovpn/releases/latest) · [قابلیت‌ها](docs/FEATURES.md) · [راهنمای مدیر](docs/OWNER-GUIDE.md) · [English](#english)

---

## ساختار مخزن

این مخزن حاصل ادغام سه پروژهٔ MolidoVPN با حفظ کامل تاریخچهٔ گیت هر کدام است:

- **ریشه** (`lib/`, `cloudflare/`, `site/`, `docs/`, `tools/`) — برنامهٔ ویندوز، سرور (Worker) و سایت. توسعهٔ فعال همین‌جا انجام می‌شود.
- **`android-app/`** — کد برنامهٔ اندروید (تصویری از [hidooch980/molidovpn-android](https://github.com/hidooch980/molidovpn-android)، که فعلاً خودش هم به‌طور مستقل و با به‌روزرسانی خودکار هسته‌ها فعال است — ساخت نسخهٔ اندروید همچنان از همان مخزن انجام می‌شود).
- **`aggregator/`** — اسکنر سرورها (تصویری از [hidooch980/vpn-sub](https://github.com/hidooch980/vpn-sub)، که خودش هر ۱۵ دقیقه مستقل اجرا می‌شود).

مخزن‌های اندروید و اسکنر همچنان زنده و فعال‌اند تا خط لولهٔ خودکار (تست، ساخت، انتشار) بدون وقفه کار کند؛ آدرس‌های قدیمی هم (`github.com/hidooch980/mobin-vpn`) به این مخزن ریدایرکت می‌شوند.

---

## این برنامه چیست؟

برنامه MolidoVPN با یک دکمه وصل می‌شود. خودش همهٔ راه‌ها (سرورهای V2Ray، وارپ، سایفون، تور و …) را از روی اینترنت خود شما امتحان می‌کند و بهترین را انتخاب می‌کند. رایگان است، ثبت‌نام نمی‌خواهد و رابط آن فارسی است.

## دانلود و نصب

| دستگاه | چه چیزی نصب کنید |
|---|---|
| اندروید (بیشتر گوشی‌ها) | `MolidoVPN-android-arm64.apk` از [صفحهٔ Releases](https://github.com/hidooch980/molidovpn/releases/latest) |
| اندروید قدیمی / مطمئن نیستید | `MolidoVPN-android-armv7.apk` یا `MolidoVPN-android-universal.apk` |
| ویندوز ۱۰ و ۱۱ | `MolidoVPN-windows-setup.exe` (یا نسخهٔ بدون نصب `MolidoVPN-windows-x64.zip`) |
| آیفون | برنامهٔ **Hiddify** یا **Streisand** را از App Store نصب کنید و یکی از لینک‌های اشتراک زیر را اضافه کنید |

راه ساده‌تر: [سایت برنامه](https://hidooch980.github.io/molidovpn/) را باز کنید؛ دکمهٔ مناسب دستگاه شما آنجاست.

**لینک‌های اشتراک (آیفون و هر برنامهٔ V2Ray):**

- `https://molido-sub.hidooch980.workers.dev/sub/1` تا `/sub/5` — پنج لینک با سرورهای متفاوت؛ اگر یکی کار نکرد بعدی را امتحان کنید
- `https://molido-sub.hidooch980.workers.dev/ios` — فهرست سبک مخصوص آیفون
- `https://molido-sub.hidooch980.workers.dev/hiddify` — همان فهرست به‌علاوهٔ وارپ برای Hiddify

## قابلیت‌ها

فهرست کامل و توضیح هر مورد: [docs/FEATURES.md](docs/FEATURES.md)

### حالت‌های اتصال
- **خودکار** — پیش‌فرض؛ همهٔ مسیرها را به ترتیب امتحان می‌کند
- **سرورهای V2Ray** — VLESS، VMess، Trojan، Shadowsocks، Reality، XHTTP، Hysteria2، TUIC، AnyTLS
- **وارپ (WARP / WireGuard)**، **MASQUE** و **وارپ در وارپ (WARP-on-WARP)** — اندروید
- **AmneziaWG** داخلی — بدون نیاز به وارد کردن کانفیگ، با هویت وارپ خود برنامه
- **سایفون (Psiphon)** و **تور (Tor)** — با انتخاب کشور خروج؛ در اندروید Tor/Psiphon روی وارپ هم هست
- **V2Ray از روی Psiphon** — زنجیره برای شبکه‌های خیلی بسته
- **SHARD** — سرورهای پشت CDN (اندروید)
- **فقط DNS گیمینگ** — بدون تونل، با Radar Game، Electro، Shecan و 403.online

### هوشمندی
- تست خودکار همهٔ مسیرها و سرورها از روی اینترنت خود کاربر
- پرهیز از خروجی ایران: اگر مسیری با IP ایران بیرون برود، کنار گذاشته می‌شود
- بهترین حالت برای هر اپراتور (همراه اول، ایرانسل، مخابرات …) از روی گزارش‌های ناشناس
- انتخاب کشور با تأیید واقعی کشور خروج
- اسکنر پس‌زمینه که سرورها را ساعتی تست می‌کند
- ضدقفل (anti-freeze): اگر تونل وسط کار گیر کند، به سرور پشتیبان منتقل می‌شود
- «کانفیگ‌های من»: وارد کردن با چسباندن، فایل، QR، لینک اشتراک و کلید Outline

### تجربهٔ کاربری
- نمای **ساده** و **پیشرفته**، راهنمای شروع، رابط کاملاً فارسی
- **اطلاعیه‌ها** از طرف مدیر، بالای صفحهٔ اصلی
- **معرفی به دوستان** با کد QR سایت
- **به‌روزرسانی خودکار** برنامه (حتی وقتی GitHub فیلتر است، از طریق Worker)

### حریم خصوصی
- گزارش‌های کیفیت فقط با اجازهٔ کاربر (opt-in) و **ناشناس** هستند: اثرانگشت سرور، موفق/ناموفق، تأخیر، نوع شبکه و اپراتور
- هیچ IP ای ذخیره نمی‌شود؛ آمار به‌صورت روزانه جمع‌بندی و بعد از ۳۰ روز پاک می‌شود

### زیرساخت
- **جمع‌کنندهٔ سرور** ([vpn-sub](https://github.com/hidooch980/vpn-sub)) هر ۱۵ دقیقه سرورها را تست می‌کند و هر ساعت منابع جدید پیدا می‌کند
- **تست محلی از ایران** روی کامپیوتر مدیر؛ سرورهای ناموفق در ایران از لینک‌ها حذف می‌شوند
- **Worker اشتراک** روی Cloudflare: نام‌گذاری یکسان `🇩🇪 MolidoVPN 01`، رتبه‌بندی با گزارش‌ها
- **پنل مدیر** (`/admin`): کانفیگ‌های VIP، وضعیت تست ایران، اطلاعیه، خاموش/روشن کردن حالت‌ها از راه دور، آمار
- هسته‌ها (sing-box، Xray، Tor، Psiphon، AmneziaWG) هر ۶ ساعت بررسی و به‌روز می‌شوند؛ انتشار فقط وقتی تست اتصال روی شبیه‌ساز اندروید موفق باشد
- گردش‌کارهای زمان‌بندی‌شده با یک commit ماهانه زنده نگه داشته می‌شوند

جزئیات فنی: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## پشتیبانی و حمایت

- پشتیبانی تلگرام: [@Molido_Vpn](https://t.me/Molido_Vpn)
- حمایت مالی: [reymit.ir/molido](https://reymit.ir/molido)

</div>

---

## English

**MolidoVPN** is a free, one-button VPN for Iranian families on **Android**, **Windows** and **iPhone** (via Hiddify/Streisand). It tests every route from the user's own connection and picks what works.

- **Download:** [latest release](https://github.com/hidooch980/molidovpn/releases/latest) (Android APKs, Windows installer/zip) or the [website](https://hidooch980.github.io/molidovpn/).
- **iPhone / any V2Ray client:** `https://molido-sub.hidooch980.workers.dev/sub/1` … `/sub/5`, `/ios`, `/hiddify`.
- **Modes:** Automatic; V2Ray servers (VLESS, VMess, Trojan, Shadowsocks, Reality, XHTTP, Hysteria2, TUIC, AnyTLS); WARP, MASQUE, WARP-on-WARP (Android); built-in AmneziaWG; Psiphon; Tor; V2Ray over Psiphon; SHARD CDN nodes (Android); gaming-DNS-only.
- **Smart:** tests all tunnels, avoids Iran exits, best mode per mobile operator, country picker with exit verification, hourly background scanner, anti-freeze failover, "My configs" import (paste/file/QR/subscription/Outline).
- **UX:** simple/advanced home, onboarding, Persian UI, owner announcements, share-with-friends QR, automatic app updates.
- **Privacy:** opt-in anonymous quality reports only; no IPs stored.
- **Infra:** server aggregator every 15 min (+ hourly source discovery), local Iran testing, Cloudflare subscription worker with owner admin panel, remote mode flags and stats, core auto-updates every 6 h gated by an emulator connect test.
- **Docs:** [Features (Persian)](docs/FEATURES.md) · [Owner guide (Persian)](docs/OWNER-GUIDE.md) · [Architecture](docs/ARCHITECTURE.md)
- **Support:** Telegram [@Molido_Vpn](https://t.me/Molido_Vpn) · Donate: [reymit.ir/molido](https://reymit.ir/molido)

## License

The Android app is a modified version of an open-source AGPL-3.0 project; its source code: https://github.com/hidooch980/molidovpn-android
