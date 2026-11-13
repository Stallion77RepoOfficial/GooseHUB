# Motor kaynakları ve kurulum

Wine, FEX ve DXMT ayrı depolarda tutulur. GooseHUB ile aynı GitHub klasöründe her deponun tek kaynak kopyası bulunur. GooseHUB’un içinde başka bir Wine veya DXMT kaynak ağacı oluşturulmaz.

Özel fork’lar esas kaynaktır. Upstream düzeltmeleri karşılaştırılarak ayrı ayrı alınır; yerel kaynaklar hazır bir paket veya başka bir kaynak ağacıyla değiştirilmez. Mevcut OpenGL, Direct3D, MSync, çeviri, kurucu ve HID düzeltmeleri korunur.

İlk `.app`, motorları içermez. İlk açılıştaki kurulum `Resources/engine-lock.json` ile belirtilen GitHub kaynaklarını çeker, bu Mac’te derler ve doğruladıktan sonra uygulamanın `Contents/Resources/Engines` klasörüne yerleştirir. Bütün zorunlu bileşenler tamamlanmadan kütüphane açılmaz.

Derleme çıktıları tek önbellekte, `~/Library/Caches/GooseHUB/Build` altında tutulur. Depolara derlenmiş DLL, Unix kütüphanesi, nesne dosyası veya `.app` eklenmez. Yerel değişiklikler ve başka depoların dosyaları otomatik olarak sıfırlanmaz.

Kurulum, tamamlanmış motor dosyalarının hash’lerini ve kaynak commitlerini kaydeder. Başarısız derleme çalışan motoru değiştirmez; kurulumun son aşaması geri alınabilir. Geçmiş performans ve uyumluluk ölçümleri yalnızca kaydedilen sürüm ve test koşulları için geçerlidir.
