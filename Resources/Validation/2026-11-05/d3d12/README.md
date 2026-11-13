# D3D12 — ULTRAKILL Prelude

Goose HUB 0.2.6 (9), Apple M4. Test oyunu, geliştiricinin yayımladığı değişmemiş ULTRAKILL Prelude 1.05b demosudur: [resmî indirme](https://hakita.itch.io/ultrakill-prelude). İndirme yaklaşık 130 MB, açılmış oyun yaklaşık 386 MB. Oyun `-force-d3d12` ile çalıştırıldı; Unity günlüğü Direct3D 12, feature level 11.1 ve Apple M4 gösteriyor.

Oyunda menü, eğitim sahnesi, HUD, aydınlatma, hareket ve yumruk görüntüsü kontrol edildi. Kullanıcı W/F ile hareketi ve tahta engelin kırılmasını doğruladı, akıcılığı iyi buldu. Sayısal çatışma FPS değeri ve aynı sahnenin tekrarlanabilir önce/sonra kaydı alınmadı; bu çalışma bir çatışma FPS artışı veya CrossOver karşılaştırması sunmuyor. Eğitim sırasında değiştirilen geçici tuşlar W/F varsayılanlarına döndürüldü.

## Değişiklikler

- Mevcut D3D12 köprüsüne kök imza okuma/dönüştürme, DXBC bağları, gerçek paylaşılan buffer belleği, typed texture görünümü ve mip seçimi eklendi.
- Stencil temizleme/karşılaştırma ve dinamik referans düzeltmesi menü ve HUD çizimini düzeltti. Çoklu vertex stream, scissor ve descriptor kopyalarında buffer offsetleri doğrulandı.
- Flip zincirinde ayrı ve kararlı backbuffer kimlikleri, kuyruk sırasına uyan Present ve yeniden boyutlandırma uygulandı.
- Diğer kuyruktan sonra gelecek sinyali beklemek, ortak fiziksel GPU kuyruğunu kilitlemiyor. Sinyalsiz null-event bekleme, sinyal gelene kadar bloklanıyor. Bekleyen işler command-list Reset sonrasında da korunuyor.
- SM6 kaynaklarının Metal residency ve erişim takibi, typed görünüm ömrü ve descriptor tablosunun kayıt sonrasında değiştirilmesi ele alındı. Değişmeyen heap için kaynak listesi tekrar kullanılıyor. Son native testte 1.024 çizimin CPU kaydı yaklaşık 1,1 ms, gönderimi yaklaşık 0,85 ms idi; bunlar oyun FPS değerleri değildir.
- DXBC compute, mevcut DXMT D3D11 çekirdeğine bağlandı. SM6 compute ve DXBC compute, sıfır olmayan UAV offsetleri dahil gerçek GPU verisiyle kontrol edildi.
- WoW64 için CPU-visible placed heap ve descriptor belleği 32 bit adres alanında tutuluyor. Shader çeviricisinin kök imza yapısı 64 bit host ABI'sine uyuyor. Upload/readback eşlemelerinde adres kesilmesi önlendi.

Bu değişiklikler genel D3D12 yollarındadır. ULTRAKILL adına bağlı renderer koşulu veya oyuna özel motor yaması eklenmedi. Test başlatıcısı D3D12'yi seçmek ve ölçüm günlüğü almak için bayrak kullanır; ürün normal kullanımda bu ölçümü açmaz.

## Doğrulama

[test-results.json](test-results.json) başarılı koşuları DLL ve test programı özetleriyle listeler. İlk native tam pakette 23 senaryo çalıştırıldı; son WoW64 düzeltmelerinden sonra mevcut binary'lerle native, x64 ve x86 kontrolleri tekrarlandı. Önceki ve son derleme sonuçları ayrı etiketlidir. GPU kontrolleri yalnızca API dönüş değerini kontrol etmez; texture piksellerini veya compute çıktısındaki 32 değeri geri okur. 64 KB heap offsetiyle üç kuyrukta gerçek buffer kopyası da geçti.

D3D9 sabitleri, sampler'lar ve ProcessVertices ile D3D11 geometry shader kontrolleri üç mimaride geçti. Wine/MSync, hızlı x87, OpenGL toplama ve D3D9 performans dosyaları korunuyor. Paket denetimi, üç D3D9 DLL'sinin ve Wine varlıklarının önceki paketle aynı olduğunu doğrular.

Tam kaynak ağacı veya upstream binary değiştirilmedi. [Kaynak denetimi](source-preservation.json) başlangıç kopyalarının SHA256 değerlerini doğrular; [incremental.patch](incremental.patch) yalnızca bu çalışmanın değişikliklerini içerir. Önceki çatala ait değişiklikler başlangıç kaynağında korunur. [Paket denetimi](bundle-integrity.json) teslim edilen varlık özetlerini ve imzayı kontrol eder.

## Teslim edilen paket

ULTRAKILL Prelude ayrı bir şişeyle Library'ye eklendi ve 0.2.6 (9) paketinin Play düğmesinden başlatıldı. [Ürün çalıştırma kaydı](production-runtime.json), D3D12/Apple M4 günlüğünü, paketle eşleşen DLL özetlerini ve global runtime seçeneklerini kaydeder. Yalnızca testte doğrulanan ULTRAKILL kayıt ayarları taşındı; W/F ve görüntü seçenekleri korundu.

[Temizlik kaydı](cleanup.json) geçici şişelerin, eski paket kopyasının ve kullanılmayan test oyunu adaylarının kaldırıldığını listeler. Kalıcı demo GooseHUB/Games altındadır; test kodları ve kaynak başlangıç kopyaları korunur. Ham test günlüklerindeki geçici yollar temizlenmiştir.

## Kapsam

D3D12 deneysel durumdadır. Bu oyun ve listelenen GPU testlerinin geçmesi, bütün D3D12 oyunlarının veya ileri özelliklerin desteklendiği anlamına gelmez. Ray tracing, mesh shader, gelişmiş interface'ler ve bütün placed-resource/aliasing kombinasyonları doğrulanmadı. Feature level 12.1 taklidi yapılmıyor; destek üst sınırı 11.1 olarak bildiriliyor. D3D9 ile aynı FPS veya bütün oyunlarda 600 FPS garantisi verilmiyor.
