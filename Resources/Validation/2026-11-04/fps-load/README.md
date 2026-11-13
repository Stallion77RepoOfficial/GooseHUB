Goose HUB 0.2.5, derleme 8. Özel Wine ve DXMT kaynakları korunarak iki genel iyileştirme eklendi: 32 bit OpenGL çağrılarının toplu aktarılması ve D3D9 shader sabitlerinin daha az kopyalama/yeniden ayırmayla yüklenmesi.

**Aynı karakterli CS kaydı**

980 karelik kayıt, sabit kamera ve 15 görünür karakter içeriyor. Boş harita ölçümü değildir. Aynı oyun dosyası, kayıt, 960×600 pencere, 32 bit OpenGL, `developer 1`, `fps_max 999` ve global hızlı x87 hesabı kullanıldı. Bu dört koşuda kare sayacı eklenmiş bir Wine DLL’si kullanılmadı. Son seçilen 512 komutlu, tip güvenli veri kopyalayan Wine modülü ölçüldü. Arka plandaki uygulamalar kapatılmadı.

| Koşu | Kare | Süre (sn) | Native timedemo FPS |
| --- | ---: | ---: | ---: |
| shipping-on01 | 980 | 5.546 | 176.698 |
| shipping-off01 | 980 | 13.524 | 72.464 |
| shipping-on02 | 980 | 5.565 | 176.095 |
| shipping-off02 | 980 | 11.227 | 87.287 |

Kapalı ortancası **79.9 FPS**, açık ortancası **176.4 FPS**; oran **2.21×**. `on/off/on/off` sırası kullanıldı. Ortam yükü değiştiği için bu rakamlar sabit 600 FPS veya başka bir ürün karşısında üstünlük garantisi değildir.

CS’nin bu sürümü OpenGL ile çalışıyor. Bu oyundaki kazanç, Wine’ın çok sayıdaki küçük OpenGL çağrısının WoW64 geçişlerini azaltıyor. D3D9 optimizasyonu CoD ve diğer D3D9 uygulamalarına uygulanıyor. Ayarlar uygulama adına göre eşleşmiyor.

**Model ve efekt ayrımı**

`camera-idle-ai-on/off-analysis.json` ayrı bir deneydir: de_dust2, 8 CT / 8 T, yerel oyuncu ve 15 gerçek bot modeli, sabit dış kamera, doğrulanan konumlar. Bot düşünmesi yalnızca bu test kopyasında durduruldu. Modelleri gizleme/gösterme ve sentetik duman/ışık aşamaları grafik yükünü ayırmak için kullanıldı. Normal oyunun botları veya oyun dosyaları değiştirilmedi. İki koşuda botların seçtiği model tipleri küçük farklar gösterdiği için tam eşleşen FPS kanıtı yukarıdaki kayıtlı sahnedir.

Bu deneyde karakterli aşamalar yaklaşık 80 FPS’den 151–156 FPS’ye, duman/ışık aşaması yaklaşık 69 FPS’den 123 FPS’ye çıktı. Kare zamanları ve %1 düşük FPS değerleri JSON/CSV dosyalarında tutuldu; bunlar ölçüm kodu içeren deney kopyasının sonuçlarıdır.

Bot düşünmesi açıkken zorlanmış sabit dizilimde büyük CPU sıçramaları görüldü. Bu koşular render karşılaştırmasından çıkarıldı. App Nap ve uzun `NtDelayExecution` beklemesi incelemeleri bu sıçramaları açıklamadı. MSync kapalı kontrolü ek hız göstermedi; ürünün MSync davranışı korundu. Bot davranışını kapatmak ürün optimizasyonu olarak kullanılmadı.

**CoD4 Bog**

1280×720, VSync kapalı, senkron pipeline derlemesi, hızlı x87 açık. Menü grupları dışarıda bırakıldı. Aşağıdaki maliyetler 1000 ve üzeri çizim içeren 60 karelik gruplardan hesaplandı.

| Koşu | Yoğun grup | Sabit yükleme µs/çizim | Hazırlık µs/çizim |
| --- | ---: | ---: | ---: |
| cod-before06 | 74 | 0.854 | 2.898 |
| cod-after03 | 121 | 0.439 | 2.425 |

Bog sahnesinin AI ve efekt akışı koşular arasında birebir aynı değildir. Bu nedenle buradaki bütün oyun FPS değerleri kesin bir yüzde artış olarak sunulmuyor. Sabit tamponlarında ayrı VS/PS halkaları, kullanılan kayıt aralığı, sarılmada discard, diğer yüklemelerde no-overwrite ve aynı değeri tekrar gönderen çağrıların elenmesi kullanıldı. Sabitler için shader değişiminde daha geniş kayıt aralığı gerektiği de izleniyor.

**Doğruluk ve geri dönüş**

- x86, x64 ve ARM64EC’de 21 sabit veri GPU kontrolü geçti: shader aralığı büyümesi, göreli adresleme, state block, int/bool, 4096 benzersiz piksel ve tampon sarılması, aşamalar arası veri korunması, sabit işlevli aşamalar ve StretchRect sonrası bağlar.
- Aynı üç mimaride 13 sampler piksel kontrolü ve 5 ProcessVertices kontrolü geçti.
- Son Wine modülü açık ve kapalıyken 11 OpenGL kontrolü geçti. Sürücünün sunmadığı ARB multitexture/debug callback testleri atlandı. İş parçacığı aktarımında mevcut renk durumu kontrol edildi; platformun varsayılan framebuffer içeriği bu aktarımda doğrulanmadı.
- 12 Swift testi geçti. Paket imzası, kaynak özetleri ve dosya özetlerinin son doğrulaması `bundle-integrity.json` içinde kaydedilir.
- Engines içindeki “Legacy OpenGL batching” kapatıldığında toplama kodu derlenmemiş normal modül yüklenir. Bakım araçları normal ortamı kullanır. Synchronous debug callback kaydı toplama yolunu kapatır; OpenGL çağrı izleme açıkken de normal çağrı yolu kullanılır.

Ek üçgen birleştirme denemesi ortanca FPS’yi artırmadığı için seçilmedi (`geometry-merge-decision.json`). Paket bu deneyin kodunu veya kare/uyku ölçüm kodunu içermiyor.

**Kaynakların korunması ve sürüm seçimi**

[Koruma denetimi](../fork-preservation.json), önceki Wine ve DXMT kaynak özetlerinin yalnızca yeni performans değişiklikleri geri alınarak birebir yeniden üretildiğini gösteriyor. Wine derleme kopyasındaki 13.256 kaynak dosyası ana çatalla karşılaştırıldı. Yeni yamalar da ters yönde kuru kontrolden geçti. D3D8/9/12, SM3/SM4 çeviricileri, native Metal köprüsü, MSync ve önceki yerel değişiklikler korunuyor.

4 Kasım kontrolünde Wine’ın son etiketi [11.21](https://github.com/wine-mirror/wine/tree/wine-11.21), DXMT ana dalı [647b0020](https://github.com/3Shain/dxmt/commit/647b0020ba5764e5593b12407afd76964fa11e20) idi. [Son 19 değişiklik](https://github.com/3Shain/dxmt/compare/3b252590cb0290e36fca6f088b5255b871d2d95a...647b0020ba5764e5593b12407afd76964fa11e20) incelendi: yeni DXIL/tessellation kodu ve bu çatala ait olmayan metotlardaki kontroller, bu eski OpenGL/D3D9 iş yükünün performans çözümü olarak alınmadı. Tam yerel çatalların yeni derlemeleri seçildi: Wine 11.11 Adrenalin 2026.11.04 ve DXMT Adrenalin 2026.11.04.

Test sahneleri APFS oyun/şişe kopyalarında kuruldu. Orijinal şişeye AMXX ölçüm eklentisi veya bot ayarı yüklenmedi. Ham çalıştırma yolları geçici test kopyalarını gösterir; bunlar temizlikte kaldırılır. GPU kontrollerinin kalıcı kaynakları depo kökündeki `scripts/` dizinindedir. Kayıtlı sahnenin dosyası ve incelemesi burada korunmuştur.

Son paket `0.2.5 (8)` imza ve 2.222 benzersiz dosya özeti kontrolünden geçti. CS, Library düğmesinden orijinal şişede başlatıldı. `production-runtime.json`, paket içindeki iki LegacyOpenGL modülünün yüklendiğini, her iki global ayarın açık olduğunu ve orijinal şişedeki D3D9 dosyalarının yeni paketle eşleştiğini kaydediyor. Geçici oyun/şişe/motor kopyaları kaldırıldı; `dist` içinde yalnızca `Goose HUB latest.app` kaldı.
