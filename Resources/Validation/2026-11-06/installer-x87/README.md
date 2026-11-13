# Kurucuda bozuk dosya yolu — 2026-11-06

Sorun, FEX’in azaltılmış x87 hassasiyetinin kurucuya da uygulanmasıydı. Aynı Inno Setup dosyası 64-bit modda yol karakterlerini bozdu; tam hassasiyette açıldı. Bu değişiklik GooseHUB’un başlatma politikasıdır. Wine ve özel DXMT ikilileri değiştirilmedi.

## Gözlenen davranış

- Dosya ve çalışma klasörü mevcuttu. Eski logda `x87MathBits: 64` vardı.
- Dosya izinde `Z:\Users\...\setup.exe` yerine `X:\Useps\...\tetup0exe` gibi değişmiş karakterler görüldü. Kurucu “Yol bulunamadı” dedi; kendi başlangıç logunu oluşturamadı.
- Aynı dosya ve test şişesiyle yalnızca x87 hassasiyeti değiştirildiğinde Inno başlangıç logu oluştu. Kullanıcı dil/kurulum penceresinin açıldığını doğruladı.
- Sonraki denemede kurucunun hedefi `Z:\Games` oldu; macOS kökünde yazma izni olmadığı için Error 5 verdi. Bu, ilk hatadan ayrı bir hedef dizin sorunuydu.
- Yeni GooseHUB başlatıcısı aynı kurucuyu `x87MathBits: 80` ile çalıştırdı. Hedef `C:\Games\Severed Steel` seçildi. Inno “Installation process succeeded” kaydetti; kullanıcı QuickSFV’de bütün dosyaların OK olduğunu doğruladı.

Hedef, kurucunun standart [`/DIR` seçeneği](https://jrsoftware.org/ishelp/topic_setupcmdline.htm) ile belirlendi. Sistem köküne klasör veya ek yazma izni eklenmedi.

## Kalıcı düzeltme

MSI paketleri, standart kurulum/kaldırma dosya adları ve PE başlığındaki Inno Setup/NSIS imzaları tam x87 hassasiyetiyle başlatılır. Yeniden adlandırılmış kurucuların imzaları da tanınır. Okuma ilk 1 MiB ile sınırlıdır. Normal uygulamalarda kullanıcının genel hızlı x87 ayarı geçerlidir; bir oyun adına göre eşleştirme eklenmedi.

Başlatma logları artık çalışma klasörünü ve seçilen 64/80-bit x87 modunu kaydeder. Arayüzdeki ayarın açıklaması kurucuların otomatik tam hassasiyet kullandığını belirtir.

## Doğrulama

14 Swift testi geçti. Kontroller kurucu/oyun ayrımını, yeniden adlandırılmış imzaları, bozuk ve kısa PE girdilerini, MSI argümanlarını, genel ayarın kapatılmasını ve mevcut OpenGL/argüman/ayar davranışlarını kapsar. Gerçek kurucu testi normal `HubService` → `ProcessInvocation` → Wine yolunu kullandı; x87 modu elle zorlanmadı.

`test-results.json` dosya kimliğini ve gerçek başlatma başlığını; Inno logları kurulum sonucunu içerir. `bundle-integrity.json`, önceki Wine/DXMT ve diğer motor dosyalarının korunduğunu doğrular. LoL/Riot istemcileri kapatılmadı; Steam kütüphanesine erişilmedi.
