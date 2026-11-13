# CoD4 kısa yeşil video karesi — 2026-11-06

Yakalanan hata DXMT’nin D3D9 sistem belleği aktarımındaydı. Video çözülmüş halde CPU belleğinde hazır olmasına rağmen `UpdateTexture`, kaynağın eski GPU kopyasını taşıyordu. Düzeltme mevcut özel DXMT üzerine eklendi; oyun adı veya Bink DLL’i için ayrı bir kural yok.

## Kanıt

- Orijinal oyunun ve şişenin ayrı APFS test kopyaları kullanıldı. Kullanıcının açık oyunu, kayıtları ve LoL/Riot süreçleri değiştirilmedi.
- CoD4 Bog yükleme videosunda, gerçek sunumdan önce GPU çıktısında üç noktada aynı **RGB (0,135,0)** karesi yakalandı. Son `Clear` rengi siyahtı; shader atlama sayacı sıfırdı.
- Aynı karede bağlı Y, U ve V dokuları GPU’da sıfırdı. `UpdateTexture` anındaki CPU örnekleri ise Y=(33,37,30), U=(128,128,128), V=(128,128,129) idi. Kaynağın son GPU yüklemesi sıfırlardan oluşuyordu. Ayrıntılar `baseline-video-*.csv` dosyalarında.
- Kaynak Bink videolarının ilk 12 karesi FFmpeg ile ayrıca çözüldü; aynı tek renk yeşil kare dosyada bulunmadı. WineD3D kontrolünde video renkliydi.

Microsoft, bu iki aktarımın sistem belleğindeki kaynaklardan yapıldığını belirtir: [UpdateTexture](https://learn.microsoft.com/en-us/windows/win32/api/d3d9/nf-d3d9-idirect3ddevice9-updatetexture), [UpdateSurface](https://learn.microsoft.com/en-us/windows/win32/api/d3d9/nf-d3d9-idirect3ddevice9-updatesurface).

## Değişiklik

`UpdateTexture` ve `UpdateSurface`, CPU’nun güncel olduğu sistem belleği kaynaklarını doğrudan hedefe yükler. Kısmi güncellemeler yalnızca istenen alanı taşır. Mip seviyeleri, küp yüzleri ve hacim seviyeleri aynı yoldan desteklenir. GPU daha yeni veri içeriyorsa mevcut GPU kopyalama yolu korunur. Mevcut format açılımı ve blok satır aralıkları yeniden kullanılır.

## Doğrulama

`test-results.json`, teslim edilen D3D11/Wine altyapısıyla çalıştırılan DLL ve test dosyası hashlerini içerir.

| Kontrol | x86 | x64 | ARM64EC |
|---|---:|---:|---:|
| Sistem belleği, format, mip, küp, hacim, kısmi alan ve GPU verisini koruma | 20/20 | 20/20 | 20/20 |
| Shader sabitleri | 21/21 | 21/21 | 21/21 |
| Sampler piksel kontrolleri | 13/13 | 13/13 | 13/13 |
| ProcessVertices | 5/5 | 5/5 | 5/5 |

Eski D3D9 DLL’i aynı 20 sistem belleği kontrolünün 16’sında hatalı piksel verdi. Yeni sürümde tamamı geçti. Testler GPU piksel okuması kullanır; FPS karşılaştırması değildir. x64 D3D9, üretimdeki ARM64EC D3D11/Wine köprüsüyle çalıştırıldı.

Gerçek oyun karşılaştırmasının kare sayıları ve sonuçları `video-comparison.json` içindedir. Tanı sürümü GPU okumasıyla senkronizasyon ekler; testin FPS sayacı performans ölçümü olarak kullanılmamalıdır. Sonuç bu yakalanmış geçiş hatası ve ölçülen senaryolar içindir.

## Özel fork ve paket

`source-preservation.json`, yalnızca bu düzeltme geri alındığında önceki teslim edilen kaynak ağacının SHA-256 değerinin birebir üretildiğini gösterir. Eklenen kaynak değişikliği beş D3D9 dosyasıyla sınırlıdır. Wine, D3D11 ve D3D12 paket dosyalarının korunduğu ayrıca `bundle-integrity.json` ile doğrulanır. Tanı DLL’i dağıtıma dahil edilmez.
