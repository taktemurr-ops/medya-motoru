# medya-motoru

Fotoğraf, Video ve Ses ailesinin motoru: 45 aracın gerçek uygulamaları, 33 dilde
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
| Gizli albüm | Parolalı, şifreli kasa: PBKDF2-HMAC-SHA256 (120 000 yineleme) ile türetilen anahtar rastgele bir veri anahtarını sarar; her dosya, küçük resmi ve dizin (dosya adları) AES-256-GCM ile şifrelenir (`cryptography`, saf Dart, ayrı isolate). Arka plana geçince kilit, yanlış parolada artan bekleme, parola değişimi (yeniden şifreleme gerekmez), tümünü silme. Arka kapı yoktur | Android, iOS (web'de dosya sistemi yok) |
| Ekran kaydedici | MediaProjection + MediaRecorder (H.264/AAC MP4), ön plan hizmeti (`foregroundServiceType="mediaProjection"`, bildirimde Durdur), çözünürlük/kare hızı/kalite, geri sayım, duraklat/sürdür (Android 7+), isteğe bağlı mikrofon; kayıt listesi, galeriye kaydetme, paylaşma | Android. iOS: uygulamalar ReplayKit ile yalnız kendi ekranlarını kaydedebilir; sistem geneli için ayrı bir Broadcast Upload Extension (ayrı hedef, App Group) gerekir, bu yüzden araç Denetim Merkezi'ndeki yerleşik Ekran Kaydı'nı adım adım anlatır |

Ekran kaydında diğer uygulamaların iç sesi (AudioPlaybackCapture) kaydedilmez; yalnız mikrofon.

## İzinler

- Fotoğraf/video seçimi Android Photo Picker ile (`READ_MEDIA_*` istenmez).
- Ses dosyaları sistem dosya seçicisiyle (SAF) açılır; müzik çalar da kütüphane taraması
  yapmaz, bu yüzden `READ_MEDIA_AUDIO` gerekmez.
- Kamera: filtreli kamera ve zaman atlamalı video. Mikrofon: ses değiştirici, ses
  düzenleyici, gürültü azaltma ve podcast. İzin istenmeden önce 33 dilde açıklama gösterilir.
- Ekran kaydı: `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`, `POST_NOTIFICATIONS`
  (bildirimdeki Durdur düğmesi için, isteğe bağlı) ve her kayıtta sistemin MediaProjection onayı.
- Zil sesi `WRITE_SETTINGS` istemez: dosya Ringtones klasörüne eklenir ve sistem ses
  ayarları açılır.

## Üretim

Metinler `proto/apps/medya/medya_titles.py` ve `medya_labels.py` dosyalarından
`proto/apps/medya/mkengine.py` ile üretilir (`lib/src/tx.dart`, `lib/src/registry.dart`).
