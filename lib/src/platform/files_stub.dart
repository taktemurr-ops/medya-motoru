library;

import 'dart:typed_data';

import 'package:video_player/video_player.dart';

/// Dosya işlemleri yok (yalnızca analiz için).
class MediaFiles {
  static bool get hasFileSystem => false;
  static Future<bool> saveImage(Uint8List bytes, String name) async => false;
  static Future<bool> saveVideo(String path, String name) async => false;
  static Future<bool> shareBytes(Uint8List bytes, String name, String mime) async => false;
  static Future<bool> sharePath(String path, String mime) async => false;
  static Future<String?> tempPath(String ext) async => null;
  static Future<String?> writeTemp(Uint8List bytes, String ext) async => null;
  static Future<Uint8List?> read(String path) async => null;
  static Future<void> delete(String path) async {}
  static Future<String?> appDir(String sub) async => null;
  static Future<List<String>> list(String dir, String ext) async => const [];
  static Future<void> clearDir(String dir) async {}
  static Future<String?> rename(String path, String newName) async => null;
  static Future<int> size(String path) async => 0;
  static Future<bool> write(String path, Uint8List bytes) async => false;
  static Future<bool> exists(String path) async => false;
  static Future<String?> getText(String url) async => null;
  static Stream<double> download(String url, String target, {String? sha256}) => const Stream<double>.empty();
  static VideoPlayerController? video(String path) => null;
  static Future<VideoPlayerController?> videoBytes(Uint8List bytes, String name) async => null;
}
