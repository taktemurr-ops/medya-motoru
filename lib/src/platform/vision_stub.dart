library;

import 'dart:ui';

class Vision {
  static bool get supported => false;
  static Future<List<Rect>> faces(String path) async => const [];
  static Future<List<Rect>> plates(String path) async => const [];
}
