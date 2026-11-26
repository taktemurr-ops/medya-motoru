/// Mobil ve masaüstü: resim ve videolar galeriye (Gal), diğer dosyalar
/// paylaşım menüsüne (share_plus) gider. Geniş depolama izni gerekmez.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

class MediaFiles {
  static bool get hasFileSystem => true;
  static int _n = 0;

  static Future<bool> saveImage(Uint8List bytes, String name) async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
        await Gal.putImageBytes(bytes);
        return true;
      } catch (_) {
        return shareBytes(bytes, name, 'image/*');
      }
    }
    return shareBytes(bytes, name, 'image/*');
  }

  static Future<bool> saveVideo(String path, String name) async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
        await Gal.putVideo(path);
        return true;
      } catch (_) {
        return sharePath(path, 'video/mp4');
      }
    }
    return sharePath(path, 'video/mp4');
  }

  static Future<bool> shareBytes(Uint8List bytes, String name, String mime) async {
    try {
      final dir = await getTemporaryDirectory();
      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final f = File('${dir.path}${Platform.pathSeparator}$safe');
      await f.writeAsBytes(bytes, flush: true);
      return await sharePath(f.path, mime);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> sharePath(String path, String mime) async {
    try {
      final r = await Share.shareXFiles([XFile(path, mimeType: mime)]);
      return r.status != ShareResultStatus.unavailable;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> tempPath(String ext) async {
    try {
      final dir = await getTemporaryDirectory();
      final d = Directory('${dir.path}${Platform.pathSeparator}medya');
      if (!await d.exists()) await d.create(recursive: true);
      _n++;
      return '${d.path}${Platform.pathSeparator}m${DateTime.now().millisecondsSinceEpoch}_$_n.$ext';
    } catch (_) {
      return null;
    }
  }

  static Future<String?> writeTemp(Uint8List bytes, String ext) async {
    final p = await tempPath(ext);
    if (p == null) return null;
    try {
      await File(p).writeAsBytes(bytes, flush: true);
      return p;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> read(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  static Future<void> delete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Uygulamanın kalıcı klasörü (ör. podcast bölümleri).
  static Future<String?> appDir(String sub) async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}$sub');
      if (!await d.exists()) await d.create(recursive: true);
      return d.path;
    } catch (_) {
      return null;
    }
  }

  /// Klasördeki bütün dosyaları siler (alt klasörlere dokunmaz).
  static Future<void> clearDir(String dir) async {
    try {
      await for (final e in Directory(dir).list()) {
        if (e is File) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static Future<List<String>> list(String dir, String ext) async {
    try {
      final out = <String>[];
      await for (final e in Directory(dir).list()) {
        if (e is File && e.path.toLowerCase().endsWith('.$ext')) out.add(e.path);
      }
      out.sort((a, b) => b.compareTo(a));
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<String?> rename(String path, String newName) async {
    try {
      final f = File(path);
      final safe = newName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final target = '${f.parent.path}${Platform.pathSeparator}$safe';
      await f.rename(target);
      return target;
    } catch (_) {
      return null;
    }
  }

  static Future<int> size(String path) async {
    try {
      return await File(path).length();
    } catch (_) {
      return 0;
    }
  }

  static Future<bool> write(String path, Uint8List bytes) async {
    try {
      await File(path).writeAsBytes(bytes, flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> exists(String path) async {
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Metin indirir (podcast akışı, OPML): en çok 8 MB, 25 sn zaman aşımı.
  static Future<String?> getText(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.acceptHeader, 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*');
      final res = await req.close().timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 25))) {
        bytes.addAll(chunk);
        if (bytes.length > 8 * 1024 * 1024) return null;
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Dosya indirir; 0..1 ilerleme yayar. Yarım kalan indirme .part dosyasında
  /// tutulur ve yalnız eksiksiz (ve [sha256] verildiyse özeti tutan) dosya
  /// hedefe taşınır; aksi hâlde .part silinir ve hata fırlatılır.
  static Stream<double> download(String url, String target, {String? sha256}) async* {
    final part = File('$target.part');
    final client = HttpClient();
    var moved = false;
    try {
      final res = await (await client.getUrl(Uri.parse(url))).close();
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final total = res.contentLength;
      final sink = part.openWrite();
      final digest = _DigestSink();
      final hasher = crypto.sha256.startChunkedConversion(digest);
      var got = 0;
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          hasher.add(chunk);
          got += chunk.length;
          if (total > 0) yield got / total;
        }
      } finally {
        await sink.close();
        hasher.close();
      }
      if (total > 0 && got != total) throw const HttpException('incomplete');
      if (sha256 != null && digest.value?.toString() != sha256.toLowerCase()) {
        throw const HttpException('sha256');
      }
      await part.rename(target);
      moved = true;
      yield 1.0;
    } finally {
      client.close(force: true);
      if (!moved) {
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
      }
    }
  }

  static VideoPlayerController? video(String path) => VideoPlayerController.file(File(path));

  /// Bayt olarak seçilen video (yalnız web'de gerekir; burada geçici dosya).
  static Future<VideoPlayerController?> videoBytes(Uint8List bytes, String name) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'mp4';
    final p = await writeTemp(bytes, ext);
    return p == null ? null : VideoPlayerController.file(File(p));
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;

  @override
  void add(crypto.Digest data) => value = data;

  @override
  void close() {}
}
