Goose HUB 0.2.2 — CS 1.6 başlatma düzeltmesi

Kayıtlı hl kısayolu `arguments: ["-game cstrike"]` içeriyordu. Kullanıcının logunda bu nedenle `valve/cl_dlls/client.dll` görülüyordu. Aynı Wine/FEX içinde küçük bir Windows programıyla argüman sınırları doğrulandı: bu dizi tek değer, `["-game", "cstrike"]` ise iki değer ulaştırıyor. REA kaydı `argument-boundary-evidence.json` içindedir.

Argüman alanı artık normal komut satırı metnini ayırıyor. Boşluk içeren yollar çift tırnakla yazılır; Windows ters eğik çizgi/çift tırnak kuralları korunur. Eski kayıtlar editöre açılırken gerektiği şekilde tırnaklanır; meşru tek değerler kendiliğinden parçalanmaz. CS kısayolu yeni uygulamanın arayüzünden düzeltilmiştir. Diğer uygulamalar ve şişe ayarları değişmemiştir.

Kopya şişedeki testte doğru CS client.dll ve GameUI.dll yüklendi; süreç 100 saniye açık kaldı. Ayrı yerel de_dust2 testinde CS sunucu DLL’i yüklendi ve ServerActivate çağrıları kaydedildi; 50 saniye sonunda test şişesi durduruldu. Wine penceresi mevcut CUA yüzeylerinde bulunamadığı için görüntü ve oynanış görsel olarak doğrulanmadı. Winebth, Kerberos ve glClear uyarıları bu testlerde de vardı; mod seçimi hatası bu satırlara bağlanamaz.

Dokuz Swift testi geçti. Paket imzası ve motor varlıklarının hash’leri doğrulandı. Wine ve DXMT kaynaklarında değişiklik yapılmadı.

Ayrıştırma kuralları: https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments
