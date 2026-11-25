/// Google ML Kit ile yüz ve plaka benzeri yazı alanlarını bulur. İşlem
/// tamamen cihazda yapılır; görüntü gönderilmez.
library;

import 'dart:io';
import 'dart:ui';

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../dsp/imaging.dart' show looksLikePlate;

class Vision {
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  static Future<List<Rect>> faces(String path) async {
    final d = FaceDetector(options: FaceDetectorOptions(performanceMode: FaceDetectorMode.accurate, minFaceSize: 0.05));
    try {
      final faces = await d.processImage(InputImage.fromFilePath(path));
      return [for (final f in faces) f.boundingBox];
    } catch (_) {
      return const [];
    } finally {
      await d.close();
    }
  }

  static Future<List<Rect>> plates(String path) async {
    final r = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final text = await r.processImage(InputImage.fromFilePath(path));
      final out = <Rect>[];
      for (final b in text.blocks) {
        for (final l in b.lines) {
          if (looksLikePlate(l.text)) out.add(l.boundingBox);
        }
      }
      return out;
    } catch (_) {
      return const [];
    } finally {
      await r.close();
    }
  }
}
