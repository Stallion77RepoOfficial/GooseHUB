Goose HUB Adrenalin Edition 0.2.1

DXMT ve Wine kendi kaynak ağaçlarımızdan derlenir. DXMT’nin D3D8/9 uygulaması, sampler önbelleği, native Metal köprüsü, LLVM uyarlamaları ve deneysel D3D12 katmanı korunmuştur. Güncel upstream’den seçilen beş hata düzeltmesi yerel kodla birleştirilmiştir.

Wine sürümü `11.11 Adrenalin 2026.10.28` olarak etiketlenmiştir. Özel fork ve ARM64/MSync uyarlaması korunur. Upstream 11.20’den yalnızca beş bağımsız düzeltme alınmıştır: bekleme kuyruğunda bellek sıralaması, macOS pencere stili çıktısının başlatılması, clipboard verisinin bırakılması, ARM64EC breakpoint RIP ofseti ve exception bayraklarının korunması. Tam commitler `Resources/engine-sources.json`, özgün yamalar `Resources/Patches/` içindedir.

İlk 11.20 tabanlı aday, diğer fork yamalarının tamamını içermediğinden paketten çıkarılmıştır. Bu aday için kaydedilmiş CPU sonuçları yeni paketin performans iddiası değildir. Kaynak karşılaştırmasında Wine’ın 13.250 kaynak dosyası eski native fork ile aynı, beş dosyası seçilen yamalarla farklıdır. Eksik kaynak dosyası yoktur. DXMT’nin D3D9 karşılaştırmasında 38 dosya aynı, iki dosya sampler optimizasyonunu içerir. Kayıt: `Resources/Validation/2026-10-28/fork-preservation.json`.

Arayüzden Ready/Included rozetleri, tanıtım kartı, yapay oyun görselleri, sloganlar ve tekrar eden durum göstergeleri kaldırılmıştır. Arama, favoriler, filtreler, sıralama, liste/kart seçimi, FPS sınırı, shader ayarları ve log okuma korunur. Motor sayfası gerçek paket sürümlerini gösterir.

Doğrulamalar:

- Beş Swift testi geçti.
- Yeni şişe, uygulamanın CLI yolu üzerinden oluşturuldu.
- x86 ve x64 DXMT örnekleri 13’er sampler piksel kontrolünü geçti.
- Geometry shader bir ve üç nokta için doğru piksel sayısını üretti.
- Bekleme/uyandırma testi x86 ve x64’te 160.000’er işlemi hatasız tamamladı.
- WineD3D aynı 13 piksel kontrolünü geçti. Başlangıçtaki bilinen OpenGL glClear uyarısı sonuçları etkilemedi.

Motor politikası `ENGINE-POLICY.md`, derleme betiği `scripts/build-wine.sh`, paketleyici `scripts/stage-wine-runtime.py` dosyasındadır. Doğrulama çıktıları `Resources/Validation/2026-10-28/` içinde tutulur. `dist/` yalnızca son uygulamayı içerir; eski paketler ve geçici test kopyaları temizlenir.

CoD4, kopya oyun/şişede 60 saniye çalıştırıldı: 33 sahne ölçüm grubu, sıfır critical-section ve invalid-render-target uyarısı. Bu çalışma FPS karşılaştırması değildir.
CoD4 başlangıç kaydında iki WineD3D glClear uyarısı ve winebth sürücüsü başlatma hatası da var. Oyun sahnesi çizildi; Bluetooth aygıt desteği bu çalışmada doğrulanmadı.
