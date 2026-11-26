/// Video oynatıcı, gizli albüm ve ekran kaydedicinin saf mantığı
/// (arayüzden bağımsız, testli): SRT altyazı ayrıştırma, oynatma listesi
/// sırası, A-B tekrar, kaldığı yerden devam, kasanın şifreleme biçimi
/// (PBKDF2-HMAC-SHA256 + AES-256-GCM), ekran kaydı boyutları.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// ============================================================ oynatıcı

/// Tek bir altyazı satırı.
class Cue {
  final Duration start, end;
  final String text;
  const Cue(this.start, this.end, this.text);
}

final RegExp _srtTime = RegExp(r'(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{1,2}):(\d{1,2})[,.](\d{1,3})');

Duration _dur(String h, String m, String s, String ms) => Duration(
      hours: int.parse(h),
      minutes: int.parse(m),
      seconds: int.parse(s),
      milliseconds: int.parse(ms.padRight(3, '0')),
    );

/// SRT (ve basit WebVTT) altyazısını ayrıştırır. Biçim etiketleri (<i>, {\an8})
/// temizlenir; bozuk bloklar atlanır. Başlangıca göre sıralı döner.
List<Cue> parseSrt(String raw) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').replaceFirst('﻿', '');
  final out = <Cue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final i = lines.indexWhere((l) => _srtTime.hasMatch(l));
    if (i < 0) continue;
    final m = _srtTime.firstMatch(lines[i])!;
    final start = _dur(m[1]!, m[2]!, m[3]!, m[4]!);
    final end = _dur(m[5]!, m[6]!, m[7]!, m[8]!);
    final body = lines
        .sublist(i + 1)
        .join('\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\{\\[^}]*\}'), '')
        .trim();
    if (body.isEmpty || end <= start) continue;
    out.add(Cue(start, end, body));
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

/// [pos] anındaki altyazı (yoksa boş). [offset] altyazıyı kaydırır.
String cueAt(List<Cue> cues, Duration pos, {Duration offset = Duration.zero}) {
  final p = pos - offset;
  var lo = 0, hi = cues.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final c = cues[mid];
    if (p < c.start) {
      hi = mid - 1;
    } else if (p >= c.end) {
      lo = mid + 1;
    } else {
      return c.text;
    }
  }
  return '';
}

/// 1:02:03 ya da 02:03.
String fmtTime(Duration d) {
  final neg = d.isNegative;
  final x = d.abs();
  final h = x.inHours, m = x.inMinutes % 60, s = x.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0'), ss = s.toString().padLeft(2, '0');
  return '${neg ? '-' : ''}${h > 0 ? '$h:$mm' : mm}:$ss';
}

/// Tekrar kipi.
enum PlayRepeat { off, one, all }

/// Oynatma listesinde sıradaki öğe (yoksa null). [order] karıştırma sırası.
int? nextIndex(int current, int length, PlayRepeat mode, {List<int>? order}) {
  if (length == 0) return null;
  if (mode == PlayRepeat.one) return current;
  final seq = order ?? List<int>.generate(length, (i) => i);
  final at = seq.indexOf(current);
  if (at < 0) return seq.first;
  if (at + 1 < seq.length) return seq[at + 1];
  return mode == PlayRepeat.all ? seq.first : null;
}

/// Önceki öğe (başta ise kendisi).
int previousIndex(int current, int length, {List<int>? order}) {
  if (length == 0) return 0;
  final seq = order ?? List<int>.generate(length, (i) => i);
  final at = seq.indexOf(current);
  return at > 0 ? seq[at - 1] : current;
}

/// Karışık sıra; [first] başta kalır.
List<int> shuffledOrder(int length, int first, math.Random r) {
  final rest = [for (var i = 0; i < length; i++) if (i != first) i]..shuffle(r);
  return [if (first >= 0 && first < length) first, ...rest];
}

/// A-B tekrar: konum B'yi geçtiyse A'ya dönülecek konum, değilse null.
Duration? abJump(Duration pos, Duration? a, Duration? b) {
  if (a == null || b == null || b <= a) return null;
  return pos >= b ? a : null;
}

/// Kaldığı yerden devam: baştan 5 sn'den az ya da sona 10 sn'den az kaldıysa
/// kaydetmeye değmez (null = sil).
Duration? resumePoint(Duration pos, Duration total) {
  if (total <= Duration.zero) return null;
  if (pos < const Duration(seconds: 5)) return null;
  if (total - pos < const Duration(seconds: 10)) return null;
  return pos;
}

/// Dosyayı tanıyan anahtar (ad + boyut): yol değişse de konum hatırlanır.
String resumeKey(String name, int size) => '${name.toLowerCase()}|$size';

/// Oynatma hızı seçenekleri.
const List<double> kSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];

// ============================================================ gizli albüm

/// Kasa biçimi sürümü ve parametreleri.
const int kVaultVersion = 1;
/// PBKDF2-HMAC-SHA256 tur sayısı (OWASP 2023: SHA-256 için en az 600.000;
/// saf Dart'ta orta sınıf telefonda açılışı makul tutmak için 310.000).
/// Daha az turla kurulmuş eski kasalar parolayla açılınca bu değere yükseltilir.
const int kVaultIterations = 310000;

/// Başlıktaki tur sayısının kabul edilen aralığı (değiştirilmiş başlıkla
/// cihazı kilitleyecek kadar uzun türetme denenmez).
const int kVaultMinIterations = 1000;
const int kVaultMaxIterations = 5000000;
const String _verifierText = 'gs100-vault-ok';

final AesGcm _aes = AesGcm.with256bits();

Uint8List _rand(int n) {
  final r = math.Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

/// Paroladan 256 bit anahtar (PBKDF2-HMAC-SHA256).
Future<Uint8List> deriveKey(String password, List<int> salt, {int iterations = kVaultIterations}) async {
  final pb = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256);
  final k = await pb.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  return Uint8List.fromList(await k.extractBytes());
}

/// AES-256-GCM: çıktı = nonce(12) + şifreli metin + etiket(16).
Future<Uint8List> sealBytes(List<int> key, List<int> clear) async {
  final box = await _aes.encrypt(clear, secretKey: SecretKey(key), nonce: _aes.newNonce());
  return Uint8List.fromList(box.concatenation());
}

/// [sealBytes] çıktısını açar; anahtar yanlışsa ya da veri bozuksa null.
Future<Uint8List?> openBytes(List<int> key, List<int> sealed) async {
  try {
    final box = SecretBox.fromConcatenation(sealed, nonceLength: 12, macLength: 16);
    return Uint8List.fromList(await _aes.decrypt(box, secretKey: SecretKey(key)));
  } catch (_) {
    return null;
  }
}

/// Kasanın başlığı (açık metin JSON): tuz, yineleme, parolayla sarılmış veri
/// anahtarı ve doğrulayıcı. Parola değişince yalnız sarılmış anahtar yenilenir.
class VaultHeader {
  final int version;
  final int iterations;
  final Uint8List salt;
  final Uint8List wrappedKey;
  final Uint8List verifier;
  const VaultHeader(this.version, this.iterations, this.salt, this.wrappedKey, this.verifier);

  String toJson() => jsonEncode({
        'v': version,
        'it': iterations,
        'salt': base64Encode(salt),
        'key': base64Encode(wrappedKey),
        'check': base64Encode(verifier),
      });

  static VaultHeader? fromJson(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      final h = VaultHeader(
        (j['v'] as num).toInt(),
        (j['it'] as num).toInt(),
        base64Decode(j['salt'] as String),
        base64Decode(j['key'] as String),
        base64Decode(j['check'] as String),
      );
      if (h.iterations < kVaultMinIterations || h.iterations > kVaultMaxIterations || h.salt.length < 16) return null;
      return h;
    } catch (_) {
      return null;
    }
  }
}

/// Yeni kasa: rastgele veri anahtarı üretir, parolayla sarar.
/// Dönen: (başlık, veri anahtarı).
Future<(VaultHeader, Uint8List)> createVault(String password, {int iterations = kVaultIterations}) async {
  final salt = _rand(16);
  final dataKey = _rand(32);
  final pk = await deriveKey(password, salt, iterations: iterations);
  final wrapped = await sealBytes(pk, dataKey);
  final check = await sealBytes(dataKey, utf8.encode(_verifierText));
  return (VaultHeader(kVaultVersion, iterations, salt, wrapped, check), dataKey);
}

/// Parolayla veri anahtarını açar; yanlış parolada null.
Future<Uint8List?> unlockVault(VaultHeader h, String password) async {
  final pk = await deriveKey(password, h.salt, iterations: h.iterations);
  final dataKey = await openBytes(pk, h.wrappedKey);
  if (dataKey == null || dataKey.length != 32) return null;
  final check = await openBytes(dataKey, h.verifier);
  if (check == null || utf8.decode(check, allowMalformed: true) != _verifierText) return null;
  return dataKey;
}

/// Parola değişimi: aynı veri anahtarı yeni tuz ve parolayla yeniden sarılır.
Future<VaultHeader> rewrapVault(VaultHeader h, Uint8List dataKey, String newPassword, {int? iterations}) async {
  final salt = _rand(16);
  final it = iterations ?? h.iterations;
  final pk = await deriveKey(newPassword, salt, iterations: it);
  return VaultHeader(h.version, it, salt, await sealBytes(pk, dataKey), h.verifier);
}

/// Kasa eski (daha az turlu) ayarla mı kurulmuş: parolayla açılınca yükseltilir.
bool vaultNeedsUpgrade(VaultHeader h) => h.iterations < kVaultIterations;

/// Veri anahtarının bu kasaya ait olduğunu doğrulayıcıyla denetler.
Future<bool> checkVaultKey(VaultHeader h, List<int> dataKey) async {
  if (dataKey.length != 32) return false;
  final check = await openBytes(dataKey, h.verifier);
  return check != null && utf8.decode(check, allowMalformed: true) == _verifierText;
}

// ------------------------------------------------------------ biyometrik açma
//
// Parola asıl anahtardır. Biyometrik açma açılınca rastgele 256 bit bir sır
// üretilir ve platformun güvenli deposunda (Android Keystore ile şifreli,
// iOS Anahtar Zinciri "yalnız bu cihaz") tutulur; veri anahtarı bu sırla
// AES-256-GCM ile sarılıp kasa klasörüne yazılır (bio.bin). Sır ya da sarılı
// anahtar tek başına işe yaramaz; kapatınca ikisi de silinir.

/// Biyometrik sır (32 bayt, rastgele).
Uint8List newBioSecret() => _rand(32);

/// Veri anahtarını biyometrik sırla sarar.
Future<Uint8List> wrapBioKey(List<int> secret, List<int> dataKey) => sealBytes(secret, dataKey);

/// Sarılı anahtarı açar ve kasa doğrulayıcısıyla denetler; olmazsa null.
Future<Uint8List?> unwrapBioKey(VaultHeader h, List<int> secret, List<int> wrapped) async {
  if (secret.length != 32) return null;
  final k = await openBytes(secret, wrapped);
  if (k == null || !await checkVaultKey(h, k)) return null;
  return k;
}

/// Kasadaki bir öğe (dizin şifreli saklanır; dosya adları görünmez).
class VaultItem {
  final String id;
  final String name;
  final bool video;
  final int size;
  final int added; // ms
  const VaultItem(this.id, this.name, this.video, this.size, this.added);

  Map<String, Object?> toJson() => {'id': id, 'name': name, 'video': video, 'size': size, 'added': added};

  static VaultItem? fromJson(Object? o) {
    if (o is! Map) return null;
    final id = o['id'], name = o['name'];
    if (id is! String || name is! String || !RegExp(r'^[a-f0-9]{16,40}$').hasMatch(id)) return null;
    return VaultItem(id, name, o['video'] == true, (o['size'] as num?)?.toInt() ?? 0, (o['added'] as num?)?.toInt() ?? 0);
  }
}

String encodeIndex(List<VaultItem> items) => jsonEncode([for (final i in items) i.toJson()]);

List<VaultItem> decodeIndex(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is! List) return [];
    return j.map(VaultItem.fromJson).whereType<VaultItem>().toList();
  } catch (_) {
    return [];
  }
}

/// Öğe kimliği (rastgele, dosya adı olarak güvenli).
String newItemId() => _rand(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Parola kuralı: en az 4 karakter.
bool passwordOk(String p) => p.runes.length >= 4;

/// Art arda yanlış denemeden sonra bekleme süresi (5. yanlıştan itibaren
/// 30 sn, her 5 yanlışta ikiye katlanır; en çok 15 dk).
Duration lockoutFor(int failures) {
  if (failures < 5) return Duration.zero;
  final steps = (failures - 5) ~/ 5;
  final s = 30 * math.pow(2, steps).toInt();
  return Duration(seconds: math.min(s, 900));
}

// ============================================================ ekran kaydı

/// Kayıt boyutu: ekranın kısa kenarı [shortSide]'a ölçeklenir (0 = özgün),
/// iki kenar da 16'nın katına yuvarlanır (H.264 kodlayıcıları için).
({int w, int h}) recordSize(int screenW, int screenH, int shortSide) {
  final short = math.min(screenW, screenH);
  final s = shortSide <= 0 || shortSide >= short ? 1.0 : shortSide / short;
  int r16(double v) => math.max(16, (v / 16).round() * 16);
  return (w: r16(screenW * s), h: r16(screenH * s));
}

/// Kalite → bit hızı (bit/sn), çözünürlük ve kare hızına göre.
int recordBitrate(int w, int h, int fps, int quality) {
  // quality: 0 düşük, 1 orta, 2 yüksek → piksel başına bit.
  const bpp = [0.06, 0.1, 0.16];
  final b = (w * h * fps * bpp[quality.clamp(0, 2)]).round();
  return b.clamp(1000000, 40000000);
}

/// Kayıt dosya adı: ekran_2026-11-25_14-03-09.mp4
String recordFileName(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'ekran_${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}-${two(t.minute)}-${two(t.second)}.mp4';
}

/// Ekran kaydında ses kaynağı.
enum ScreenAudio { none, mic, app, appAndMic }

/// Seçimlere göre kayıt sesi: uygulama sesi Android 10+ (API 29) ve mikrofon
/// izni ister (Android, AudioPlaybackCapture için de RECORD_AUDIO arar).
ScreenAudio screenAudioMode({required bool app, required bool mic, required bool appSupported, required bool permission}) {
  if (!permission) return ScreenAudio.none;
  final a = app && appSupported;
  if (a && mic) return ScreenAudio.appAndMic;
  if (a) return ScreenAudio.app;
  return mic ? ScreenAudio.mic : ScreenAudio.none;
}

/// Yerel hizmetin bildirdiği ses uyarısı → metin anahtarı.
String? screenAudioWarningKey(String? warning) => switch (warning) {
      'internal_unavailable' => 'app_audio_failed',
      'internal_silent' => 'app_audio_silent',
      'internal_old' => 'app_audio_old',
      'internal_perm' => 'app_audio_perm',
      _ => null,
    };

/// 16 bit PCM karıştırma: uygulama sesi (stereo, LRLR…) + mikrofon (mono),
/// taşmada kırpılır. Yerel kodla aynı kural (test için Dart karşılığı).
Int16List mixPcm16(Int16List? stereo, Int16List? mono, int frames) {
  final out = Int16List(frames * 2);
  for (var i = 0; i < frames; i++) {
    final m = mono == null || i >= mono.length ? 0 : mono[i];
    for (var c = 0; c < 2; c++) {
      final j = i * 2 + c;
      final a = stereo == null || j >= stereo.length ? 0 : stereo[j];
      out[j] = (a + m).clamp(-32768, 32767);
    }
  }
  return out;
}
