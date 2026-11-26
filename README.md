# medya-motoru

Fotoğraf, Video ve Ses ailesinin motoru: 48 aracın gerçek uygulamaları, 33 dilde
metinleri ve merkez görünümü (onaylı oyun merkezi tasarımının mor-mercan "stüdyo" tonu).

- Çatı: `studio_core/apps` (AppTool, merkez kabuğu, reklam/satın alma, gizlilik, favoriler).
- Her araç kendi ince deposunda (`uyg-*`) yayımlanır; merkez uygulama
  `merkez-fotograf-video-ve-ses`.
- Çevrimdışı çalışır. İnternet yalnızca iki isteğe bağlı model indirmesi için kullanılır
  (otomatik altyazı ve deneysel renklendirme); ikisi de kullanıcı düğmeye basınca iner.
- Reklam yalnızca araçtan çıkarken (doğal ara, 3 dakika arayla) gösterilir; işlem
  sırasında asla. Ödüllü reklamla bugünlük açılan ekstralar: 10'dan fazla fotoğrafı
  birlikte sıkıştırma, 20 sayfadan uzun PDF, 200'den fazla fotoğrafta kopya arama,
  64×64 piksel tuvali.

## Yerel eklenti (motorun kendisi)

`medya_motoru` aynı zamanda bir Flutter eklentisidir (`android/`, `ios/`); kullanım dışı
kalan `ffmpeg_kit` yerine işletim sisteminin kendi çatıları kullanılır:

| İş | Android | iOS |
| --- | --- | --- |
| Kes, birleştir, sıkıştır, hız, ses çıkar, WAV→M4A | Media3 Transformer 1.9.2 | AVAssetExportSession / AVMutableComposition |
| Fotoğraflardan video (slayt, zaman atlamalı) | Media3 Transformer (görsel girdisi) | AVAssetWriter |
| Ses çözme (her biçim → WAV) | MediaExtractor + MediaCodec | AVAssetReader |
| Videodan kare alma (GIF) | MediaMetadataRetriever | AVAssetImageGenerator |
| Yapay zekâ modelleri | ONNX Runtime Android 1.22.0 (.onnx) | Core ML (.mlmodel) |
| Zil sesi olarak ekleme | MediaStore "Ringtones" (Android 10+, izinsiz) | — (paylaşım + GarageBand ipucu) |

Android Java ile yazıldı (Kotlin eklentisi yok): AGP 8 ve AGP 9 ile uyumlu. Media3 sürümü
`video_player_android` ile aynı tutulmalıdır (karışık Media3 sürümleri desteklenmez).

Web'de video düzenleme kapsam dışıdır; ilgili araçlar "web'de yok" der. Fotoğraf, tasarım,
ses (WAV) ve müzik araçları web'de de çalışır; GIF web'de fotoğraflardan yapılır.

## Modeller

| Model | Kullanım | Lisans | Boyut | Kaynak |
| --- | --- | --- | --- | --- |
| U²-Netp (`u2netp.onnx` / `.mlmodel`) | Arka plan silme | Apache-2.0 (U-2-Net) | ~5 MB, ilk kullanımda indirilir | https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx (SHA-256 `309c8469…`) |
| Real-ESRGAN general-x4v3 (`realesr_general_x4v3.onnx` / `.mlmodel`) | ×4 iyileştirme | BSD-3-Clause | ~5 MB, ilk kullanımda indirilir | Resmî ağırlık https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth (SHA-256 `8dc7edb9…`) → `tool/convert_models.py` |
| whisper.cpp tiny (`ggml-tiny.bin`) | Otomatik altyazı | MIT | ~75 MB, ilk kullanımda indirilir | https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin |
| Zhang ECCV16 renklendirme (`colorization_eccv16.onnx` / `.mlmodel`) | Deneysel renklendirme | BSD-2-Clause | ~129 MB, isteğe bağlı indirme | Resmî ağırlık `colorization_release_v1-9b330a0b.pth` (SHA-256 `9b330a0b…`) → `tool/convert_models.py` |

Modeller uygulamaya gömülmez. `.github/workflows/models.yml` kaynakları SHA-256 ile
doğrular, Android için ONNX'i, iOS için `coremltools` ile Core ML (`.mlmodel`,
NeuralNetwork, iOS 14+) dosyasını üretip bu deponun `models-v1` sürümüne ekler ve
macOS'ta Core ML çıktısını ONNX Runtime ile karşılaştırır. Uygulama modeli ilk
kullanımda bir kez indirir (`Models`, sürüm eklerinin SHA-256 değerleri sabit), sonra
internetsiz çalışır. Android ONNX Runtime, iOS Core ML kullanır (ONNX Runtime iOS
pod'u yok); iki platformda girdi/çıktı tensörleri ve Dart ön/son işleme aynıdır.

Yüz bulma ve plaka benzeri yazı bulma Google ML Kit ile cihazda yapılır (Android/iOS);
web'de bu araç yalnızca elle bulanıklaştırma sunar.

## 2. tur araçları

| Araç | Ne yapar | Platform |
| --- | --- | --- |
| Video oynatıcı | Oynatma listesi (sürükle-sırala), kaldığı yerden devam, 0,25–3× hız, tekrar (tek/tümü), karıştırma, A-B tekrar, çift dokunma ±10 sn, SRT/VTT altyazı (±0,5 sn kaydırma), sığdır/doldur/uzat, kontrol kilidi, uyku zamanlayıcısı, yatay görünüm | Android, iOS (video_player); web'de seçilen dosya bellekten (blob) oynatılır, liste oturumluk |
| Gizli albüm | Parolalı, şifreli kasa: PBKDF2-HMAC-SHA256 (120 000 yineleme) ile türetilen anahtar rastgele bir veri anahtarını sarar; her dosya, küçük resmi ve dizin (dosya adları) AES-256-GCM ile şifrelenir (`cryptography`, saf Dart, ayrı isolate). Arka plana geçince kilit, yanlış parolada artan bekleme, parola değişimi (yeniden şifreleme gerekmez), tümünü silme. İsteğe bağlı biyometrik açma (`local_auth`): veri anahtarı, `flutter_secure_storage` ile Android Keystore / iOS Anahtar Zinciri'nde (yalnız bu cihaz) tutulan rastgele 256 bit bir sırla sarılır (`bio.bin`); parola asıl anahtar olarak kalır, kapatınca sır ve sarılı anahtar silinir. Arka kapı yoktur | Android, iOS (web'de dosya sistemi yok) |
| Ekran kaydedici | MediaProjection + MediaRecorder (H.264/AAC MP4), ön plan hizmeti (`foregroundServiceType="mediaProjection"`, bildirimde Durdur), çözünürlük/kare hızı/kalite, geri sayım, duraklat/sürdür (Android 7+), isteğe bağlı mikrofon ve uygulama sesi (Android 10+: AudioPlaybackCapture + mikrofon karışımı, MediaCodec + MediaMuxer); kayıt listesi, galeriye kaydetme, paylaşma | Android. iOS: uygulamalar ReplayKit ile yalnız kendi ekranlarını kaydedebilir; sistem geneli için ayrı bir Broadcast Upload Extension (ayrı hedef, App Group) gerekir, bu yüzden araç Denetim Merkezi'ndeki yerleşik Ekran Kaydı'nı adım adım anlatır |

Uygulama sesi (Android 10+) yalnız ses yakalamaya izin veren uygulamalardan alınır (USAGE_MEDIA/GAME/UNKNOWN);
`allowAudioPlaybackCapture=false` diyen uygulamalar, aramalar ve korumalı içerik kayıtta sessiz kalır
(hiç ses gelmezse kullanıcıya bildirilir). Android 9 ve öncesinde ya da yakalayıcı kurulamazsa kayıt
eski yoldan (MediaRecorder, isteğe bağlı mikrofon) sürer ve bu söylenir.

## 4. tur araçları

| Araç | Ne yapar | Platform |
| --- | --- | --- |
| Vesikalık ve biyometrik fotoğraf | 20 ülke/belge şablonu (TR pasaport/kimlik 50×60, ABD 2×2 inç, Birleşik Krallık, Schengen vizesi, Kanada 50×70, Çin 33×48, Vietnam 40×60 …) — ölçüler ve varsa baş yüksekliği resmî kaynaktan, kaynak adı ekranda; özel ölçü. ML Kit yüz bulma ile otomatik çerçeveleme + oval baş kılavuzu, elle kaydırma/yakınlaştırma; isteğe bağlı arka plan değiştirme (arka plan silme aracındaki U²-Netp modeli, beyaz/açık gri/kırık beyaz/açık mavi); 300 dpi tek fotoğraf ya da 10×15 cm baskı sayfası (kesim çizgili). "Kabul garantisi yoktur, güncel kuralları kontrol edin" uyarısı | Android, iOS; web'de yüz bulma ve arka plan değiştirme yok (elle çerçeveleme ve baskı sayfası çalışır) |
| Ekolayzır ve bas güçlendirici | 10 bant (31 Hz–16 kHz, ±12 dB, RBJ tepe filtreleri) + bas rafı, 10 hazır ayar, eğri çizimi; seçilen dosya cihazda işlenir ve uygulama içi oynatıcıda çalar (ayar değişince aynı konumdan yeniden işlenir), işlenmiş ses kaydedilebilir (M4A/WAV). **Sistem geneli:** yalnız Android'de, ses oturumunu `ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION` ile duyuran oynatıcılara `android.media.audiofx.Equalizer` eklenir (eğri cihaz bantlarına ara değerlenir); uygulama süreci yaşadıkça geçerlidir, oturumunu duyurmayan oynatıcılar ve efektleri engelleyen cihazlar etkilenmez. Kullanımdan kalkmış genel karışım oturumu (0) kullanılmaz | Uygulama içi her yerde; sistem geneli yalnız Android (iOS ve web bunu açıkça yazar) |
| Podcast / RSS oynatıcı | Yalnız kullanıcının eklediği RSS 2.0 (iTunes uzantıları) ve Atom akışları — katalog ya da hazır akış **yok**; OPML içe/dışa aktarma; bölüm indirme (uygulama klasörüne, çevrimdışı dinleme), kaldığı yerden sürdürme, dinlendi işareti, 0,75–2,5× hız, 15 sn geri / 30 sn ileri | Android, iOS; web'de indirme yok ve pek çok akış CORS nedeniyle açılmaz (bildirilir) |

## İzinler

- Fotoğraf/video seçimi Android Photo Picker ile (`READ_MEDIA_*` istenmez).
- Ses dosyaları sistem dosya seçicisiyle (SAF) açılır; müzik çalar da kütüphane taraması
  yapmaz, bu yüzden `READ_MEDIA_AUDIO` gerekmez.
- Kamera: filtreli kamera ve zaman atlamalı video. Mikrofon: ses değiştirici, ses
  düzenleyici, gürültü azaltma ve podcast. İzin istenmeden önce 33 dilde açıklama gösterilir.
- Ekran kaydı: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`, `FOREGROUND_SERVICE_MICROPHONE`
  (ses kaydı sürerken; uygulama sesi de `RECORD_AUDIO` ister), `POST_NOTIFICATIONS`
  (bildirimdeki Durdur düğmesi için, isteğe bağlı) ve her kayıtta sistemin MediaProjection onayı.
- Gizli albüm biyometrik açma: `USE_BIOMETRIC` (local_auth), iOS `NSFaceIDUsageDescription`
  (merkez uygulamada 33 dilde). Android'de MainActivity `FlutterFragmentActivity` olmalıdır.
- Zil sesi `WRITE_SETTINGS` istemez: dosya Ringtones klasörüne eklenir ve sistem ses
  ayarları açılır.

## Üretim

Metinler `proto/apps/medya/medya_titles.py` ve `medya_labels.py` dosyalarından
`proto/apps/medya/mkengine.py` ile üretilir (`lib/src/tx.dart`, `lib/src/registry.dart`).
