/// 4. tur medya araçlarının arayüzsüz (test edilebilir) mantığı:
/// vesikalık fotoğraf ölçüleri ve çerçeveleme, ekolayzır filtreleri ve
/// hazır ayarları, podcast RSS/OPML ayrıştırma.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:xml/xml.dart';

import 'dsp/audio.dart';

// ================================================================ vesikalık

/// Belge türü: 0 pasaport, 1 vize, 2 kimlik kartı.
class IdPhotoSpec {
  final String id;

  /// ISO 3166 ülke kodu (Schengen vizesi için 'EU').
  final String country;
  final int kind;
  final double widthMm, heightMm;

  /// Çene–tepe baş yüksekliği aralığı (mm); 0: kaynakta ayrıca belirtilmemiş.
  final double headMinMm, headMaxMm;

  /// Önerilen zemin ([kIdBackgrounds] sırası).
  final int background;

  /// Kuralların alındığı resmî kaynak (alan adı / belge).
  final String source;

  const IdPhotoSpec(this.id, this.country, this.kind, this.widthMm, this.heightMm,
      {this.headMinMm = 0, this.headMaxMm = 0, this.background = 0, required this.source});

  bool get hasHead => headMinMm > 0 && headMaxMm > 0;

  /// Çerçevelemede kullanılan baş oranı (yükseklikten); kaynak vermiyorsa
  /// ICAO 9303'ün %70–80 aralığının ortası.
  double get headFraction => hasHead ? (headMinMm + headMaxMm) / 2 / heightMm : 0.75;

  String get sizeText => '${_mm(widthMm)}×${_mm(heightMm)} mm';
}

String _mm(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Zemin renkleri: beyaz, açık gri, kırık beyaz, açık mavi.
const List<int> kIdBackgrounds = [0xFFFFFFFF, 0xFFE4E4E4, 0xFFF1EEE6, 0xFFD9E7F4];

/// Ülke ölçü şablonları. Ölçüler ilgili resmî kaynaktan alınmıştır; kurallar
/// değişebilir (uygulama "kabul garantisi yok" uyarısı gösterir).
const List<IdPhotoSpec> kIdPhotoSpecs = [
  IdPhotoSpec('tr_passport', 'TR', 0, 50, 60, source: 'nvi.gov.tr (biyometrik fotoğraf)'),
  IdPhotoSpec('tr_id', 'TR', 2, 50, 60, source: 'nvi.gov.tr (biyometrik fotoğraf)'),
  IdPhotoSpec('us_passport', 'US', 0, 50.8, 50.8, headMinMm: 25.4, headMaxMm: 34.9, source: 'travel.state.gov'),
  IdPhotoSpec('us_visa', 'US', 1, 50.8, 50.8, headMinMm: 25.4, headMaxMm: 34.9, source: 'travel.state.gov'),
  IdPhotoSpec('gb_passport', 'GB', 0, 35, 45, headMinMm: 29, headMaxMm: 34, background: 1, source: 'gov.uk/photos-for-passports'),
  IdPhotoSpec('eu_visa', 'EU', 1, 35, 45, headMinMm: 32, headMaxMm: 36, background: 1, source: 'ICAO Doc 9303 · EU Visa Code'),
  IdPhotoSpec('de_passport', 'DE', 0, 35, 45, headMinMm: 32, headMaxMm: 36, background: 1, source: 'bundesdruckerei.de · ICAO 9303'),
  IdPhotoSpec('fr_passport', 'FR', 0, 35, 45, headMinMm: 32, headMaxMm: 36, background: 1, source: 'ants.gouv.fr · ICAO 9303'),
  IdPhotoSpec('it_passport', 'IT', 0, 35, 45, headMinMm: 32, headMaxMm: 36, source: 'poliziadistato.it · ICAO 9303'),
  IdPhotoSpec('es_passport', 'ES', 0, 26, 32, source: 'interior.gob.es'),
  IdPhotoSpec('nl_passport', 'NL', 0, 35, 45, headMinMm: 26, headMaxMm: 30, background: 1, source: 'rijksoverheid.nl (fotomatrix)'),
  IdPhotoSpec('ca_passport', 'CA', 0, 50, 70, headMinMm: 31, headMaxMm: 36, source: 'canada.ca'),
  IdPhotoSpec('au_passport', 'AU', 0, 35, 45, headMinMm: 32, headMaxMm: 36, source: 'passports.gov.au'),
  IdPhotoSpec('jp_passport', 'JP', 0, 35, 45, headMinMm: 32, headMaxMm: 36, source: 'mofa.go.jp'),
  IdPhotoSpec('kr_passport', 'KR', 0, 35, 45, headMinMm: 32, headMaxMm: 36, source: 'passport.go.kr'),
  IdPhotoSpec('cn_visa', 'CN', 1, 33, 48, headMinMm: 28, headMaxMm: 33, source: 'visaforchina.cn'),
  IdPhotoSpec('in_visa', 'IN', 1, 50.8, 50.8, headMinMm: 25.4, headMaxMm: 34.9, source: 'indianvisaonline.gov.in'),
  IdPhotoSpec('ru_visa', 'RU', 1, 35, 45, source: 'mid.ru'),
  IdPhotoSpec('my_passport', 'MY', 0, 35, 50, source: 'imi.gov.my'),
  IdPhotoSpec('vn_passport', 'VN', 0, 40, 60, source: 'xuatnhapcanh.gov.vn'),
];

/// Basılı çıktı çözünürlüğü (nokta/inç).
const int kIdDpi = 300;

int mmToPx(double mm, {int dpi = kIdDpi}) => (mm / 25.4 * dpi).round();

/// Fotoğraftaki yüz kutusundan (ML Kit: alın–çene) belge oranında bir kesim
/// dikdörtgeni hesaplar: baş (tepe–çene) [spec.headFraction] kadar yer kaplar,
/// yatayda ortalanır, tepenin üstünde kalan boşluk yaklaşık eşittir.
Rect idCropForFace(Rect face, IdPhotoSpec spec) {
  // Yüz kutusu kabaca kaş üstü–çene arasını kapsar; tepe biraz daha yukarıdadır.
  final headTop = face.top - face.height * 0.32;
  final headH = face.bottom - headTop;
  final cropH = headH / spec.headFraction;
  final cropW = cropH * spec.widthMm / spec.heightMm;
  final topGap = (cropH - headH) * 0.42;
  final cx = face.center.dx;
  return Rect.fromLTWH(cx - cropW / 2, headTop - topGap, cropW, cropH);
}

/// Baskı sayfası yerleşimi: [sheetW]×[sheetH] mm kâğıda, kenar boşluğu ve
/// aralıkla sığan kopyaların sol-üst köşeleri (mm).
List<(double, double)> idSheetSlots(IdPhotoSpec spec, {double sheetW = 152.4, double sheetH = 101.6, double margin = 3, double gap = 2}) {
  final cols = ((sheetW - 2 * margin + gap) / (spec.widthMm + gap)).floor();
  final rows = ((sheetH - 2 * margin + gap) / (spec.heightMm + gap)).floor();
  if (cols <= 0 || rows <= 0) return const [];
  final usedW = cols * spec.widthMm + (cols - 1) * gap;
  final usedH = rows * spec.heightMm + (rows - 1) * gap;
  final x0 = (sheetW - usedW) / 2, y0 = (sheetH - usedH) / 2;
  return [
    for (var r = 0; r < rows; r++)
      for (var c = 0; c < cols; c++) (x0 + c * (spec.widthMm + gap), y0 + r * (spec.heightMm + gap)),
  ];
}

// ================================================================ ekolayzır

/// 10 bant merkez frekansları (Hz), ISO oktav.
const List<double> kEqFreqs = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// Hazır ayar kimlikleri; adları `eq_presets` etiketinde aynı sırada.
const List<String> kEqPresetIds = [
  'flat', 'bass', 'treble', 'vocal', 'rock', 'pop', 'jazz', 'classical', 'electronic', 'speech', 'custom',
];

/// Hazır ayarların bant kazançları (dB) ve bas güçlendirme (dB). 'custom' boş.
const Map<String, (List<double>, double)> kEqPresets = {
  'flat': ([0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 0),
  'bass': ([6, 5, 4, 2, 0, 0, 0, 0, 0, 0], 4),
  'treble': ([0, 0, 0, 0, 0, 1, 3, 5, 6, 6], 0),
  'vocal': ([-3, -2, -1, 1, 3, 4, 3, 1, 0, -1], 0),
  'rock': ([5, 4, 2, -1, -2, -1, 2, 4, 5, 5], 0),
  'pop': ([-1, 1, 3, 4, 3, 0, -1, -1, 1, 2], 0),
  'jazz': ([3, 2, 1, 2, -1, -1, 0, 1, 2, 3], 0),
  'classical': ([4, 3, 2, 1, 0, 0, 0, 1, 2, 3], 0),
  'electronic': ([5, 4, 1, 0, -2, 1, 0, 2, 4, 5], 2),
  'speech': ([-6, -4, -2, 0, 2, 4, 4, 3, 0, -3], 0),
};

const double kEqMaxDb = 12;

/// İkinci dereceden filtre katsayıları (a0'a bölünmüş, RBJ Audio EQ Cookbook).
class EqCoef {
  final double b0, b1, b2, a1, a2;
  const EqCoef(this.b0, this.b1, this.b2, this.a1, this.a2);

  /// Tepe (peaking) filtresi.
  factory EqCoef.peak(double rate, double freq, double db, {double q = 1.41}) {
    final a = math.pow(10, db / 40).toDouble();
    final w = 2 * math.pi * freq.clamp(10.0, rate / 2 - 10) / rate;
    final cw = math.cos(w), alpha = math.sin(w) / (2 * q);
    final a0 = 1 + alpha / a;
    return EqCoef((1 + alpha * a) / a0, -2 * cw / a0, (1 - alpha * a) / a0, -2 * cw / a0, (1 - alpha / a) / a0);
  }

  /// Alçak raf (low shelf, S = 1) — bas güçlendirme.
  factory EqCoef.lowShelf(double rate, double freq, double db) {
    final a = math.pow(10, db / 40).toDouble();
    final w = 2 * math.pi * freq / rate;
    final cw = math.cos(w), sa = math.sqrt(a), alpha = math.sin(w) / 2 * math.sqrt2;
    final a0 = (a + 1) + (a - 1) * cw + 2 * sa * alpha;
    return EqCoef(
      a * ((a + 1) - (a - 1) * cw + 2 * sa * alpha) / a0,
      2 * a * ((a - 1) - (a + 1) * cw) / a0,
      a * ((a + 1) - (a - 1) * cw - 2 * sa * alpha) / a0,
      -2 * ((a - 1) + (a + 1) * cw) / a0,
      ((a + 1) + (a - 1) * cw - 2 * sa * alpha) / a0,
    );
  }

  /// [freq] frekansındaki kazanç (dB).
  double responseDb(double rate, double freq) {
    final w = 2 * math.pi * freq / rate;
    final c1 = math.cos(w), s1 = math.sin(w), c2 = math.cos(2 * w), s2 = math.sin(2 * w);
    final nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
    final dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
    final mag = math.sqrt((nr * nr + ni * ni) / math.max(1e-30, dr * dr + di * di));
    return 20 * math.log(math.max(1e-12, mag)) / math.ln10;
  }
}

/// Bant kazançları + bas güçlendirmeden filtre zinciri (0 dB bantlar atlanır).
List<EqCoef> eqChain(double rate, List<double> gains, double bassDb) => [
      if (bassDb.abs() > 0.05) EqCoef.lowShelf(rate, 100, bassDb),
      for (var i = 0; i < kEqFreqs.length && i < gains.length; i++)
        if (gains[i].abs() > 0.05 && kEqFreqs[i] < rate / 2) EqCoef.peak(rate, kEqFreqs[i], gains[i]),
    ];

/// Toplam eğri (dB) — çizim ve Android sistem eşitleyicisi için.
double eqCurveDb(double freq, List<double> gains, double bassDb, {double rate = 48000}) {
  var db = 0.0;
  for (final c in eqChain(rate, gains, bassDb)) {
    db += c.responseDb(rate, freq);
  }
  return db;
}

/// Kırpılmayı önleyen ön kazanç (dB, ≤ 0): eğrinin tepe noktasının tersi.
double eqPreampDb(List<double> gains, double bassDb) {
  var peak = 0.0;
  for (var i = 0; i <= 60; i++) {
    final f = 20 * math.pow(1000, i / 60).toDouble();
    peak = math.max(peak, eqCurveDb(f, gains, bassDb));
  }
  return -peak;
}

/// Sesi eşitleyiciden geçirir (kanal başına ayrı filtre durumu), ön kazanç ve
/// yumuşak sınırlayıcı uygular. Yalıtılmış işlemde (compute) çalıştırılabilir.
Pcm applyEq((Pcm, List<double>, double) a) {
  final (src, gains, bass) = a;
  final out = Float32List(src.samples.length);
  final ch = src.channels;
  final chain = eqChain(src.rate.toDouble(), gains, bass);
  final pre = math.pow(10, eqPreampDb(gains, bass) / 20).toDouble();
  for (var c = 0; c < ch; c++) {
    final x1 = List<double>.filled(chain.length, 0), x2 = List<double>.filled(chain.length, 0);
    final y1 = List<double>.filled(chain.length, 0), y2 = List<double>.filled(chain.length, 0);
    for (var i = c; i < src.samples.length; i += ch) {
      var v = src.samples[i] * pre;
      for (var k = 0; k < chain.length; k++) {
        final f = chain[k];
        final y = f.b0 * v + f.b1 * x1[k] + f.b2 * x2[k] - f.a1 * y1[k] - f.a2 * y2[k];
        x2[k] = x1[k];
        x1[k] = v;
        y2[k] = y1[k];
        y1[k] = y;
        v = y;
      }
      out[i] = v;
    }
  }
  final p = Pcm(src.rate, ch, out);
  softLimit(p);
  return p;
}

/// Android sistem eşitleyicisi için 20 Hz–20 kHz arası 31 noktalık eğri
/// (log aralıklı; Java tarafı cihaz bantlarına doğrusal ara değerler).
List<double> eqCurvePoints(List<double> gains, double bassDb) {
  final pre = eqPreampDb(gains, bassDb);
  return [
    for (var i = 0; i < 31; i++) eqCurveDb(20 * math.pow(1000, i / 30).toDouble(), gains, bassDb) + pre * 0.5,
  ];
}

// ================================================================ podcast

class PodcastEpisode {
  final String guid, title, url, description;
  final DateTime? published;
  final int seconds;
  const PodcastEpisode(
      {required this.guid, required this.title, required this.url, this.description = '', this.published, this.seconds = 0});

  Map<String, Object?> toJson() => {
        'g': guid, 't': title, 'u': url, 'd': description,
        'p': published?.millisecondsSinceEpoch, 's': seconds,
      };

  static PodcastEpisode? fromJson(Object? m) {
    if (m is! Map) return null;
    final u = m['u'], t = m['t'];
    if (u is! String || t is! String) return null;
    final p = m['p'];
    return PodcastEpisode(
      guid: m['g'] is String ? m['g'] as String : u,
      title: t,
      url: u,
      description: m['d'] is String ? m['d'] as String : '',
      published: p is num ? DateTime.fromMillisecondsSinceEpoch(p.toInt(), isUtc: true) : null,
      seconds: m['s'] is num ? (m['s'] as num).toInt() : 0,
    );
  }
}

class PodcastFeed {
  final String url, title, author, image;
  final List<PodcastEpisode> episodes;
  const PodcastFeed({required this.url, required this.title, this.author = '', this.image = '', this.episodes = const []});
}

/// Yalnızca http(s) adresleri kabul edilir.
bool isFeedUrl(String s) {
  final u = Uri.tryParse(s.trim());
  return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty;
}

String stripHtml(String s) => s
    .replaceAll(RegExp(r'<(br|p|/p|div|/div|li)[^>]*>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .replaceAll(RegExp(r'\n\s*\n+'), '\n')
    .trim();

/// "01:02:03", "62:03" ya da "3723" → saniye.
int parseDuration(String s) {
  final p = s.trim().split(':');
  var total = 0;
  for (final x in p) {
    final v = int.tryParse(x.trim().split('.').first);
    if (v == null) return 0;
    total = total * 60 + v;
  }
  return total;
}

const List<String> _months = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];

/// RFC 822 / 2822 tarihi ("Wed, 02 Oct 2002 13:00:00 GMT", "+0200") ya da ISO 8601.
DateTime? parseFeedDate(String s) {
  final t = s.trim();
  if (t.isEmpty) return null;
  final iso = DateTime.tryParse(t);
  if (iso != null) return iso.toUtc();
  final m = RegExp(r'(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{2,4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?\s*([+-]\d{4}|[A-Za-z]+)?').firstMatch(t);
  if (m == null) return null;
  final mon = _months.indexOf(m.group(2)!.toLowerCase());
  if (mon < 0) return null;
  var y = int.parse(m.group(3)!);
  if (y < 100) y += y < 70 ? 2000 : 1900;
  var d = DateTime.utc(y, mon + 1, int.parse(m.group(1)!), int.tryParse(m.group(4) ?? '') ?? 0,
      int.tryParse(m.group(5) ?? '') ?? 0, int.tryParse(m.group(6) ?? '') ?? 0);
  final z = m.group(7) ?? '';
  if (RegExp(r'^[+-]\d{4}$').hasMatch(z)) {
    final sign = z.startsWith('-') ? -1 : 1;
    final off = Duration(hours: int.parse(z.substring(1, 3)), minutes: int.parse(z.substring(3, 5)));
    d = sign > 0 ? d.subtract(off) : d.add(off);
  } else {
    const zones = {'EST': -5, 'EDT': -4, 'CST': -6, 'CDT': -5, 'MST': -7, 'MDT': -6, 'PST': -8, 'PDT': -7};
    final h = zones[z.toUpperCase()];
    if (h != null) d = d.subtract(Duration(hours: h));
  }
  return d;
}

String _text(XmlElement? e) => e == null ? '' : e.innerText.trim();

XmlElement? _child(XmlElement e, String local, {String? prefix}) {
  for (final c in e.childElements) {
    if (c.name.local == local && c.name.prefix == prefix) return c;
  }
  return null;
}

/// RSS 2.0 (iTunes uzantılarıyla) ya da Atom akışını ayrıştırır. Yalnızca ses/
/// video eki (enclosure) olan bölümler alınır. Geçersizse null.
PodcastFeed? parseFeed(String url, String body) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (_) {
    return null;
  }
  final root = doc.rootElement;
  final eps = <PodcastEpisode>[];
  if (root.name.local == 'rss' || root.name.local == 'RDF') {
    final ch = root.findAllElements('channel').firstOrNull;
    if (ch == null) return null;
    final title = _text(_child(ch, 'title'));
    var author = _text(_child(ch, 'author', prefix: 'itunes'));
    if (author.isEmpty) author = _text(_child(ch, 'author'));
    var image = _child(ch, 'image', prefix: 'itunes')?.getAttribute('href') ?? '';
    if (image.isEmpty) image = _text(_child(ch, 'image')?.findElements('url').firstOrNull);
    for (final it in ch.findElements('item')) {
      final enc = _child(it, 'enclosure');
      final u = enc?.getAttribute('url') ?? '';
      if (!isFeedUrl(u)) continue;
      final t = _text(_child(it, 'title'));
      final guid = _text(_child(it, 'guid'));
      final desc = _text(_child(it, 'summary', prefix: 'itunes')).isNotEmpty
          ? _text(_child(it, 'summary', prefix: 'itunes'))
          : _text(_child(it, 'description'));
      eps.add(PodcastEpisode(
        guid: guid.isEmpty ? u : guid,
        title: t.isEmpty ? u.split('/').last : t,
        url: u,
        description: stripHtml(desc),
        published: parseFeedDate(_text(_child(it, 'pubDate'))),
        seconds: parseDuration(_text(_child(it, 'duration', prefix: 'itunes'))),
      ));
    }
    return PodcastFeed(url: url, title: title.isEmpty ? url : stripHtml(title), author: stripHtml(author), image: image, episodes: eps);
  }
  if (root.name.local == 'feed') {
    final title = _text(_child(root, 'title'));
    final author = _text(_child(root, 'author')?.findElements('name').firstOrNull);
    for (final en in root.findElements('entry')) {
      String u = '';
      for (final l in en.findElements('link')) {
        if (l.getAttribute('rel') == 'enclosure') u = l.getAttribute('href') ?? '';
      }
      if (!isFeedUrl(u)) continue;
      final id = _text(_child(en, 'id'));
      eps.add(PodcastEpisode(
        guid: id.isEmpty ? u : id,
        title: _text(_child(en, 'title')),
        url: u,
        description: stripHtml(_text(_child(en, 'summary'))),
        published: parseFeedDate(_text(_child(en, 'updated')).isNotEmpty ? _text(_child(en, 'updated')) : _text(_child(en, 'published'))),
      ));
    }
    return PodcastFeed(url: url, title: title.isEmpty ? url : title, author: author, episodes: eps);
  }
  return null;
}

/// OPML'deki akışlar: (başlık, adres).
List<(String, String)> parseOpml(String body) {
  try {
    final doc = XmlDocument.parse(body);
    return [
      for (final o in doc.findAllElements('outline'))
        if (isFeedUrl(o.getAttribute('xmlUrl') ?? ''))
          (o.getAttribute('title') ?? o.getAttribute('text') ?? '', o.getAttribute('xmlUrl')!.trim()),
    ];
  } catch (_) {
    return const [];
  }
}

/// Abonelikleri OPML 2.0 olarak yazar.
String buildOpml(List<(String, String)> feeds) {
  final b = XmlBuilder();
  b.processing('xml', 'version="1.0" encoding="UTF-8"');
  b.element('opml', attributes: {'version': '2.0'}, nest: () {
    b.element('head', nest: () => b.element('title', nest: 'Podcasts'));
    b.element('body', nest: () {
      for (final f in feeds) {
        b.element('outline', attributes: {'type': 'rss', 'text': f.$1, 'title': f.$1, 'xmlUrl': f.$2});
      }
    });
  });
  return b.buildDocument().toXmlString(pretty: true);
}

/// İndirilen bölüm için güvenli dosya adı (adresin özetinden).
String episodeFileName(String url) {
  var h = 0x811c9dc5;
  for (final c in url.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  final path = Uri.tryParse(url)?.path ?? '';
  final dot = path.lastIndexOf('.');
  var ext = dot >= 0 ? path.substring(dot + 1).toLowerCase() : 'mp3';
  if (!RegExp(r'^[a-z0-9]{2,4}$').hasMatch(ext)) ext = 'mp3';
  return 'ep_${h.toRadixString(16).padLeft(8, '0')}.$ext';
}

/// Oynatma hızları.
const List<double> kPodcastSpeeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5];
