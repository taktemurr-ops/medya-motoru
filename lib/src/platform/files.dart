/// Dosya kaydetme, paylaşma ve geçici dosyalar (web'de tarayıcı indirmesi).
library;

export 'files_stub.dart' if (dart.library.io) 'files_io.dart' if (dart.library.js_interop) 'files_web.dart';
