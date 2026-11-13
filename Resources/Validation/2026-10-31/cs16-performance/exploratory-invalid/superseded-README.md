# CS 1.6 performans incelemesi — 31 Ekim 2026

## Ölçüm düzeltmesi

Uzun doğrulama sırasında `status` çıktısı 0 aktif oyuncu gösterdi. Önceki tablodaki kısa testlerde yerel istemcinin haritaya bağlandığı doğrulanmamıştı. Bu FPS değerleri gerçek oyun performansı iddiası için geçersizdir. Kullanıcı boş yerel haritada ciddi drop bildirdi. Test akışı bağlantı doğrulamasıyla yeniden kuruluyor.

Oyunun `hw.dll` motoru DXMT'nin D3D8/9/11 DLL'lerini yüklemiyor. Kayıtlarda yalnızca Wine'ın DDRAW, WineD3D ve OpenGL DLL'leri var. Şişenin “DXMT” seçimi bu oyunun DirectDraw/D3D7 çağrılarını DXMT'ye dönüştürmüyor. Özel DXMT ve Wine kaynakları ile teslim edilen motor dosyaları değiştirilmedi.

Aynı de_dust2 sahnesi, 960×600 pencere, MSync ve 100 FPS oyun sınırı kullanıldı. Kullanıcının şişesi APFS kopyasıyla ayrıldı; MetalGoose izinleri verilmediğinden ölçekleme veya kare üretimi çalışmadı. FPS, GoldSrc `wait` komutları arasındaki süreyle yaklaşık ölçüldü ve test amaçlı Wine OpenGL sunum sayaçlarıyla kontrol edildi. Sunum örnekleri iki saniyelik aralıklardır; açılış, harita yükleme ve kapanış örnekleri de ham kayıtta bulunur. `timerefresh` ayrı bir çizim testidir; canlı oyun FPS'i olarak kullanılmaz.

| Deneme | Yaklaşık canlı FPS | timerefresh FPS |
|---|---:|---:|
| Eski D3D, 16 bit, HUD açık | 37.0 | 59.3 |
| Eski D3D, 16 bit, HUD kapalı | 37.1 | 62.7 |
| Eski D3D, 32 bit, HUD açık | 38.6 | 80.6 |
| OpenGL, 32 bit, HUD açık | 98.1 | 514.0 |
| Eski kayıt ayarı üzerine `-gl -32bpp` | 92.3 | 700.1 |
| Aynı parametreler, teslim edilen motorla son tekrar | 97.8 | 530.1 |

Doğrudan sayımda OpenGL sahnesi yaklaşık 89–99 sunum/s değerine ulaştı. Eski yolda yalnızca 32 bite geçmek veya HUD'u kapatmak sorunu çözmedi. CPU örneğinde eski yolun WineD3D iş parçacığı `macdrv_surface_flush → NSOpenGLContext flushBuffer → CGLFlushDrawable` içinde ekran sunumunu bekliyor. OpenGL bu eski DirectDraw ön tampon yolunu kullanmıyor.

Kapasite denemelerinde yalnızca kopyada `developer 1 / fps_max 1000` kullanıldı: eşitleme açıkken yaklaşık 119 FPS, uygulamaya özel AllowVerticalSync=N ile yaklaşık 131 FPS. Bu denemeler binlerce canlı FPS iddiasını doğrulamadı. Kullanıcının `fps_max 100` ayarı ve eşitleme ayarları korunuyor. Arka planda Riot/LoL istemcisi CPU ve GPU kullanıyordu; sonuçlar donanımın boş sistemdeki tavanı veya CrossOver karşılaştırması değildir.

CS kısayolu uygulamanın kendi düzenleme ekranından `-game cstrike -gl -32bpp` olarak kaydedildi. Diğer kısayollar ve şişe seçenekleri karşılaştırılarak korundukları doğrulandı. Gerçek şişe bu kısayoldan başlatıldı; üretim oturumu başlığı `-gl -32bpp` parametrelerini doğruluyor. Görsel titreme için kullanıcı gözlemi bekleniyor; burada görsel olarak giderildiği iddia edilmez. Başlangıçtaki ortak GL framebuffer uyarılarından ikisi OpenGL yolunda da kalıyor.

Geçici OpenGL sayacı yalnızca deneme motoruna konuldu. Kaynak kopyası geri yüklendi, normal OpenGL Unix DLL'i tekrar derlendi ve tanılama işaretinin güncel derlemede bulunmadığı kontrol edildi. Uygulamanın 2.219 motor varlığı hash'leriyle ve kod imzasıyla doğrulandı.

`measure-live.py`, iki CPU örneği, yerel demo, ham yükleme/sunum kayıtları ve her denemenin JSON sonucu bu klasörde. İlk keşif denemelerindeki örnekleyici yükü olan ölçümler sonuç tablosuna alınmadı. Tekrar için ayrı bir şişe kopyası ve o kopyayı gösteren `environment.json` gerekir; betik kendi bulunduğu klasörün bu dosyasını okur.

GoldSrc `-gl` ve `-32bpp` parametreleri için [Valve'ın açılış seçenekleri belgesi](https://help.steampowered.com/en/faqs/view/7D01-D2DD-D75E-2955) de kontrol edildi.
