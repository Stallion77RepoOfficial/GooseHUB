Goose HUB Adrenalin Edition 0.2.1, 28 Ekim 2026

Güncel paket kendi DXMT ve Wine fork’larımızı kullanır. Wine, 11.11 tabanlı özel kaynak ağacı ile native ARM64/MSync uyarlamasının tamamını içerir; 11.20 kaynağından beş bağımsız hata düzeltmesi alındı. 11.20 tabanlı ilk aday diğer fork yamalarının tamamını içermediğinden dağıtımdan çıkarıldı. Aşağıdaki 11.20 karşılaştırması bu eski adayın kaydıdır; 0.2.1 için performans iddiası değildir.

Wine’da 13.250 kaynak dosyası eski native fork ile birebir eşleşti. Değişen beş dosyanın farkları seçilen upstream yamalarıyla doğrulandı; kaynak eksiği yok. DXMT’nin D3D9 karşılaştırmasında 38 dosya aynı, iki dosya sampler optimizasyonunu içeriyor. D3D8/9, D3D12 deneysel katmanı, native Metal köprüsü ve diğer yerel kaynaklar korunuyor. Karşılaştırma kaydı: `Resources/Validation/2026-10-28/fork-preservation.json`.

Arayüzden tanıtım kartı, yapay oyun görselleri, Ready/Included rozetleri, tekrar eden durumlar ve sloganlar kaldırıldı. Favori, arama, filtre, liste/kart görünümü, log okuma ve motor ayarları korunuyor.

Kaynaklar [Wine 11.20](https://github.com/wine-mirror/wine/blob/wine-11.20/ANNOUNCE.md) ve [DXMT geliştirme dalının incelenen sürümü](https://github.com/3Shain/dxmt/commit/3b252590cb0290e36fca6f088b5255b871d2d95a). DXMT’nin son etiketli paketi [v0.80](https://github.com/3Shain/dxmt/releases/tag/v0.80); bu paket fork’taki D3D8/9 uygulamasının yerine geçirilmedi. Tam commit kimlikleri, seçim gerekçesi ve port yaması uygulamanın Engines/Sources dizinine de konuldu.

Kitaplığa kart/liste görünümü, favoriler, son oynanan sıralaması, şişe filtresi, çalışan uygulama ve bulunamayan dosya göstergeleri eklendi. Şişeler FPS sınırı, shader önbelleği ve derleme davranışını ayrı ayrı ayarlayabiliyor. Oturumlar filtrelenebiliyor ve logların son 256 KB’ı uygulama içinde okunabiliyor. Motor sayfası paketlenen gerçek sürümleri gösteriyor. Değişmeyen veriler artık her üç saniyede arayüzü yeniden oluşturmuyor.

Aynı DXMT DLL’leriyle, her Wine sürümü için dört dönüşümlü x86 koşusunun medyanları aşağıda. Her koşuda 60.000 çizim ve 13 piksel doğrulaması var. CPU gönderim süresi ölçülüyor; sonuçlar oyun FPS kazancı veya CrossOver’a karşı FPS üstünlüğü olarak yorumlanamaz.

| Sampler davranışı | Wine 11.11, µs/çizim | Wine 11.20, µs/çizim | Azalma |
|---|---:|---:|---:|
| Sabit | 1.7892 | 1.5585 | %12.9 |
| Her 64 çizimde değişim | 1.7616 | 1.5749 | %10.6 |
| Her çizimde değişim | 1.9374 | 1.7215 | %11.1 |

Önceki adayın doğrulamaları:

- Beş Swift testi geçti: eski kayıtların okunması, yeni seçeneklerin aktarılması, favorilerin kalıcı kaydı, sınırlandırılmış log okuma ve sürüm bilgilerinin manifestten alınması.
- x86, x64 ve ARM64EC DXMT derlemeleri tamamlandı. Native ARM64 Wine 11.20 derlendi ve yeni prefix içinde komut çalıştırdı.
- Wine 11.20 ile x86 ve x64 örnekleri 13’er sampler piksel kontrolünü geçti; karşılaştırmadaki sekiz koşu da geçti.
- WineD3D geri dönüş yolu da aynı 13 piksel kontrolünü geçti.
- Geometry shader’ın bir ve üç nokta çıktısı doğru sayıda piksel üretti. Önceki native dönüştürücü, önbellek kapalı negatif kontrolde bir nokta yerine sıfır piksel üretti.
- CoD4 `bog_a`, 1280×720, VSync kapalı ve senkron shader derlemesiyle kopya oyun/prefix üzerinde çalıştırıldı. 90 saniyelik Wine 11.20 tekrarında 50 sahne ölçüm grubu görüldü; render target veya critical-section uyarısı olmadı. Aynı DXMT ile Wine 11.11 kontrolü de sahneye girdi. Oyun içi sahne yükleri değiştiği için bu kayıtlar FPS üstünlüğü kanıtı değildir.
- İlk Wine 11.20 CoD4 koşusunda bir heap critical-section bekleme uyarısı görüldü; 45 ve 90 saniyelik tekrarlarda görülmedi. İlk prefix kurulumunda geçici aygıt servisi zaman aşımı ve Wine Mono özel eylem hatası da kaydedildi. Sonraki sorguda `winebus` ve `wineusb` çalışıyordu; yönetilen .NET programları bu çalışmada doğrulanmadı.
- CLI üzerinden FPS/shader seçeneklerinin kaydı ve geçersiz FPS değerinin reddi doğrulandı. Paket varlıkları hash’lerle, uygulama imzası deep/strict doğrulamasıyla kontrol edildi.

Ölçüm verileri ve piksel test çıktıları [Validation dizininde](/Users/berkegulacar/Downloads/Github/dxmt-adrenalin-edition/GooseHUB/Resources/Validation/2026-10-28). Yeniden derleme için [Wine betiği](/Users/berkegulacar/Downloads/Github/dxmt-adrenalin-edition/GooseHUB/scripts/build-wine.sh), [port yaması](/Users/berkegulacar/Downloads/Github/dxmt-adrenalin-edition/GooseHUB/Resources/Patches/wine-native-arm64.patch) ve [motor paketleyicisi](/Users/berkegulacar/Downloads/Github/dxmt-adrenalin-edition/GooseHUB/scripts/stage-wine-runtime.py) saklandı. Kullanıcının mevcut oyun dosyaları ve şişeleri bu testlerde değiştirilmedi.
