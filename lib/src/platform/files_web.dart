/// Web: kaydetme, tarayıcının indirme özelliğiyle yapılır. Dosya sistemi yok.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart' as web;

class MediaFiles {
  static bool get hasFileSystem => false;

  static Future<bool> _download(Uint8List bytes, String name, String mime) async {
    try {
      final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
      final url = web.URL.createObjectURL(blob);
      final a = web.HTMLAnchorElement()
        ..href = url
        ..download = name;
      web.document.body?.appendChild(a);
      a.click();
      web.document.body?.removeChild(a);
      web.URL.revokeObjectURL(url);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> saveImage(Uint8List bytes, String name) =>
      _download(bytes, name, name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg');
  static Future<bool> saveVideo(String path, String name) async => false;
  static Future<bool> shareBytes(Uint8List bytes, String name, String mime) => _download(bytes, name, mime);
  static Future<bool> sharePath(String path, String mime) async => false;
  static Future<String?> tempPath(String ext) async => null;
  static Future<String?> writeTemp(Uint8List bytes, String ext) async => null;
  static Future<Uint8List?> read(String path) async => null;
  static Future<void> delete(String path) async {}
  static Future<String?> appDir(String sub) async => null;
  static Future<List<String>> list(String dir, String ext) async => const [];
  static Future<String?> rename(String path, String newName) async => null;
  static Future<int> size(String path) async => 0;
  static Future<bool> write(String path, Uint8List bytes) async => false;
  static Future<bool> exists(String path) async => false;
  static Stream<double> download(String url, String target) => const Stream<double>.empty();
  static VideoPlayerController? video(String path) => null;

  /// Tarayıcıda seçilen videoyu bellekteki bir blob adresinden oynatır.
  static Future<VideoPlayerController?> videoBytes(Uint8List bytes, String name) async {
    try {
      final lower = name.toLowerCase();
      final mime = lower.endsWith('.webm')
          ? 'video/webm'
          : lower.endsWith('.ogv') || lower.endsWith('.ogg')
              ? 'video/ogg'
              : lower.endsWith('.mov')
                  ? 'video/quicktime'
                  : 'video/mp4';
      final blob = web.Blob(<JSAny>[bytes.toJS].toJS, web.BlobPropertyBag(type: mime));
      return VideoPlayerController.networkUrl(Uri.parse(web.URL.createObjectURL(blob)));
    } catch (_) {
      return null;
    }
  }
}
