# CS 1.6 — 31 Ekim 2026

Goose HUB 0.2.4, derleme 7. Özel Wine ve DXMT kaynakları korundu. 64 bit x87 hesabı, kullanıcının isteğiyle bütün FEX uygulamaları için ortak ve varsayılan açık ayara taşındı. CS, OpenGL 32 bit ve uygulamaya özel eşitleme kapalı olarak çalışıyor. Kullanıcı yeni ayarlarla oyunun oldukça akıcı olduğunu bildirdi. 600 FPS hedefi ölçümlerde sağlanmadı.

## Doğrulanan bulgular

- Bu CS 4554 motoru eski DirectDraw/D3D7 veya OpenGL kullanıyor. Şişede DXMT seçilmesi oyunun kendiliğinden DXMT'nin D3D8/9/11 DLL'lerine geçtiği anlamına gelmiyor. Kısayoldaki `-gl` artık kütüphanede **OpenGL** olarak gösteriliyor.
- `fps_max 999`, bu eski motordaki `developer 0` sınırını tek başına kaldırmıyor. `developer 1` ile 100 FPS üzeri ölçüldü. Ayrıca `userconfig.cfg` içindeki `fps_max 100`, kullanıcının diğer ayarını tekrar düşürüyordu; iki dosya da 999 olarak düzeltildi.
- FEX'in `FEX_X87REDUCEDPRECISION=1` seçeneği, eski x86 oyunlarındaki x87 işlemlerini 64 bit hesapla çalıştırabiliyor. [FEX'in açıklaması](https://fex-emu.com/FEX-2206/) bunun hız ve hassasiyet arasında bir tercih olduğunu belirtiyor. Ayar artık **Engines → 64-bit x87 math** altında ortak ve varsayılan açık. `runtime-settings.json` içinde saklanıyor; kısayola özel işlemci seçeneği kaldırıldı. Kapatıldığında sonraki uygulama açıkça `FEX_X87REDUCEDPRECISION=0` ile başlıyor. Wine bakım araçlarının ve Rosetta Wine yolunun ortamı korunuyor.
- Eşitleme yalnızca `HKCU\Software\Wine\AppDefaults\hl.exe\Mac Driver` altında `AllowVerticalSync`, `REG_SZ`, `N` olarak ayarlandı. Genel sürücü ayarları değiştirilmedi.

## Geçerli performans ölçümü

APFS kopyasında, yerel ve botsuz `de_dust2` haritasında bir oyuncunun bağlı olduğu RCON `status` ile doğrulandı. Oyuncu takıma katıldı; 18,12 saniyelik hareketli demo kaydedildi. Demo incelemesi sağlık değerinin 100, `onlyClientDraw` değerinin 0 olduğunu, konum ve bakış açısının değiştiğini doğruluyor. `connected-demo-inspection.json` ve `connected-dxmt-rcon.json` bu kanıtları içeriyor.

Aynı demo oyunun kendi `timedemo` komutuyla, 960×600 pencere, MSync, `developer 1`, `fps_max 999` ve uygulamaya özel eşitleme kapalı olarak oynatıldı. Her başarılı tekrar **2.110 kare** raporladı. LoL/Riot'a kapatma komutu verilmedi; arka plan yükü tekrarlar arasında sabitlenmedi.

| Yol | x87 | Metal HUD | Süre | Ortalama FPS |
|---|---:|---|---:|---:|
| OpenGL, ilk ölçüm | varsayılan | kapalı | 14,023 s | 150,467 |
| OpenGL, açıkça eski hassasiyet | 80 bit | kapalı | 13,401 s | 157,453 |
| OpenGL | 64 bit | kapalı | 10,369 s | 203,488 |
| OpenGL, tekrar | 64 bit | kapalı | 6,548 s | 322,240 |
| OpenGL | 64 bit | açık | 8,970 s | 235,224 |
| D3D7 → DxWrapper → özel DXMT | varsayılan | kapalı | 14,209 s | 148,493 |
| D3D7 → DxWrapper → özel DXMT | 64 bit | kapalı | 28,256 s | 74,675 |

600 FPS hedefi için yapılan sonraki seri:

| Yol | Metal HUD | Süre | Ortalama FPS |
|---|---|---:|---:|
| Korunan OpenGL yolu | kapalı | 5,707 s | 369,726 |
| Korunan OpenGL yolu | açık | 5,193 s | 406,311 |
| Korunan OpenGL yolu, son tekrar | açık | 5,303 s | 397,907 |
| WineMetalGL 3.7, ARM64 | kapalı | 18,858 s | 111,889 |
| WineMetalGL 3.7, sıcak tekrar | kapalı | 18,168 s | 116,137 |
| Deneysel 32 bit OpenGL çağrı tamponu | açık | 15,411 s | 136,916 |

Son seri de 64 bit x87 kullanıyor; ilk seriyle arasındaki fark global ayara geçişin kazancı olarak yorumlanmamalı. WineMetalGL ve çağrı tamponu seçilmedi. Tamponun altı piksel/durum kontrolü normal ve deneysel yolda geçti, ancak oyun performansı geriledi. Deney yalnızca geçici Wine kaynak kopyasında yapıldı; kopya kanonik kaynakla eşitlendi ve normal OpenGL modülleri tekrar derlendi. Tamponun kapalı kontrolü derlemeyle çakıştığı için performans karşılaştırmasına alınmadı. Geçici kod `test-only-gl-batch.patch` olarak kanıt klasöründe, teslim edilen Wine içinde değil.

Bunlar demo ortalamalarıdır; canlı oyunun en düşük FPS'i, yüzde 1 düşük FPS veya takılma ölçümü değildir. Tekrarlar değişken; arka plan yükünün etkisi ayrı olarak ölçülmedi. Binlerce FPS veya CrossOver üstünlüğü doğrulanmadı. WineD3D + 64 bit x87 denemesi yükleme sırasında zaman aşımına uğradı ve FPS sonucu üretmedi; nedeninin x87 ayarı olduğu kanıtlanmadı. Ayrı WineD3D sampler testleri varsayılan hassasiyetle geçti.

Global ayar açılmadan önce WineD3D sampler testi **64 bit x87 ile de** tekrarlandı ve 13 piksel kontrolünün tamamı geçti (`sampler-wined3d-global-x87.log`).

Önceki `wait` komutlu CFG testleri, oyuncu haritaya bağlanmadan ölçüm yaptığı için **geçersizdir**. Eski 37–98 FPS tablosu oyun performansı sonucu olarak kullanılmamalı. Ham kayıtlar ve eski rapor `exploratory-invalid/` altında tutuluyor. Profiling açık tekrar da karşılaştırma tablosuna alınmadı; CPU örneği yükleme kodunu içerdiğinden sabit oyun sahnesinin darboğazını kanıtlamıyor.

## DXMT düzeltmesi

D3D7 adaptörünü test ederken özel D3D9 uygulamasındaki `ProcessVertices` çağrısının `E_NOTIMPL` döndürdüğü bulundu. Işıksız, sabit işlevli CPU yolu eklendi: dünya/görünüm/izdüşüm ve viewport dönüşümü, renk/doku verileri, sınır doğrulaması ve çakışan tamponlar. Programlanabilir shader, ışıklandırma, vertex blending, doku üretimi/dönüşümü ve vertex fog işlemleri hâlâ desteklenmiyor. Tam API veya bütün kırpma durumları uygulanmış sayılmamalı.

Bu ekleme mevcut özel DXMT'nin üzerine yapıldı. DxWrapper CS için seçilmedi ve gerçek oyun klasörüne ya da uygulama paketine eklenmedi; testlerde OpenGL daha iyi sonuç verdi.

## Uygulanan kısayol

```text
-game cstrike -gl -32bpp -nojoy -noipx +developer 1 +fps_max 999 +cl_showfps 1
```

Gerçek uygulamanın ilk başlatma kaydı `production-fastx87-launch.log`, parametreleri ve `x87MathBits: 64` değerini doğruluyor. 0.2.4 ile aynı işlemci modu bütün FEX uygulamalarının ortak varsayılanı oldu; son paketten yeniden başlatma `production-global-x87-launch.log` ile doğrulandı. Diğer iki kısayolun argümanları ve şişe seçenekleri korundu; ortak işlemci modunun bu oyunlara uygulanması istenen davranış değişikliği. Karşılaştırma `shortcut-change.json` içinde. Önceki config dosyalarının yedekleri bu klasörde.

Ortak başlangıç `GL_INVALID_FRAMEBUFFER_OPERATION` uyarılarından ikisi OpenGL açılışında da kalıyor. Bu satırlar tek başına titremenin nedenini veya giderildiğini kanıtlamıyor. MetalGoose'a yeni izin verilmedi; ekran yakalama ve kare üretimi bu testlerde etkin değildi.

## Kontroller

- 11 Swift testi geçti.
- `ProcessVertices`: x86, x64 ve ARM64EC derlemelerinde beş kontrol grubu geçti; gerçek GPU çiziminin yeşil piksel sonucu okundu.
- Mevcut sampler testleri: DXMT x86 ve ARM64EC yollarında 13'er piksel kontrolü, WineD3D geri dönüş yolunda 13 kontrol geçti.
- Geçici Wine sunum sayacı kaldırıldı; normal OpenGL Unix kütüphanesi yeniden derlendi. Özel Wine kaynakları değiştirilmedi.
- Paket: 2.217 benzersiz motor varlığının SHA-256 doğrulaması ve derin/sıkı kod imzası kontrolü geçti. Güncel DLL'ler kanonik `GooseHUB/Engines` hazırlama dizinine de aktarıldı. `dist` içinde yalnızca `Goose HUB latest.app` var.

31 Ekim kaynak kontrolünde DXMT upstream başlığı önceki incelemeyle aynıydı. [Wine 11.21](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.21/ANNOUNCE.md) OpenGL değişiklikleri ayrıca incelendi: yeni WoW64 eşleme yolu `GL_MESA_map_buffer_client_pointer` uzantısını istiyor. Piksel doğrulama programında Apple M4'ün OpenGL 2.1 bağlamı bu uzantıyı sunmadı. Diğer bağlam düzeltmesi OpenGL 3.1 ile ilgili. Bu yüzden bu değişiklikler CS için kanıtlanmış hızlandırma sayılmadı; özel Wine tümüyle değiştirilmedi. Kontrol ayrıntıları `upstream-check/` altında.

`results.json` makinece okunabilir sonuçları, `package-verification.json` paket doğrulamasını içerir. Tekrar betikleri ayrı bir şişe kopyası ve yalnızca o kopyayı gösteren `environment.json` ister; gerçek kullanıcı şişesine yönlendirilmemeli.

Geçici şişe, deneysel motor kopyaları, indirilen adaptörler ve test EXE dosyaları kaldırıldı. Kanıtlar ve tekrar betikleri bu klasörde korunuyor. CS son paketle yeniden açık bırakıldı.
