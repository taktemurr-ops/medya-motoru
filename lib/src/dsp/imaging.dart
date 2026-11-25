/// Saf Dart görüntü işlemleri: renk matrisi, keskinlik, vinyet, kırpma,
/// pikselleştirme, bulanıklık, algısal karma (dHash), kolaj düzenleri ve
/// yapay zekâ modelleri için ön/son işlemler. Web dahil her yerde çalışır.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// RGBA8888 piksel tamponu.
class Rgba {
  final int width;
  final int height;
  final Uint8List data;

  Rgba(this.width, this.height, this.data) : assert(data.length == width * height * 4);

  factory Rgba.blank(int width, int height, {int r = 0, int g = 0, int b = 0, int a = 255}) {
    final d = Uint8List(width * height * 4);
    for (var i = 0; i < d.length; i += 4) {
      d[i] = r;
      d[i + 1] = g;
      d[i + 2] = b;
      d[i + 3] = a;
    }
    return Rgba(width, height, d);
  }

  Rgba copy() => Rgba(width, height, Uint8List.fromList(data));

  int index(int x, int y) => (y * width + x) * 4;
}

int _c8(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

// --------------------------------------------------------------- renk matrisi

/// Flutter `ColorFilter.matrix` ile aynı biçimde 4×5 matris (ofsetler 0..255).
List<double> identityMatrix() => <double>[
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0,
      0, 0, 1, 0, 0,
      0, 0, 0, 1, 0,
    ];

/// Önce [b], sonra [a] uygulanmış gibi birleştirir (a∘b).
List<double> combineMatrix(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 5; c++) {
      var v = 0.0;
      for (var k = 0; k < 4; k++) {
        v += a[r * 5 + k] * b[k * 5 + c];
      }
      if (c == 4) v += a[r * 5 + 4];
      out[r * 5 + c] = v;
    }
  }
  return out;
}

/// [v] -1..1 arası parlaklık.
List<double> brightnessMatrix(double v) {
  final o = v * 100;
  return <double>[1, 0, 0, 0, o, 0, 1, 0, 0, o, 0, 0, 1, 0, o, 0, 0, 0, 1, 0];
}

/// [v] -1..1 arası kontrast.
List<double> contrastMatrix(double v) {
  final c = 1 + v;
  final o = 128 * (1 - c);
  return <double>[c, 0, 0, 0, o, 0, c, 0, 0, o, 0, 0, c, 0, o, 0, 0, 0, 1, 0];
}

/// [s] 0 (gri) .. 1 (aynı) .. 2 (çok canlı).
List<double> saturationMatrix(double s) {
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final i = 1 - s;
  return <double>[
    lr * i + s, lg * i, lb * i, 0, 0, //
    lr * i, lg * i + s, lb * i, 0, 0,
    lr * i, lg * i, lb * i + s, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

/// [v] -1 (soğuk) .. 1 (sıcak).
List<double> warmthMatrix(double v) {
  final o = v * 30;
  return <double>[1, 0, 0, 0, o, 0, 1, 0, 0, o * 0.3, 0, 0, 1, 0, -o, 0, 0, 0, 1, 0];
}

/// Hazır filtreler.
const List<String> kFilterIds = ['none', 'mono', 'sepia', 'vivid', 'cool', 'warm', 'fade', 'vintage'];

List<double> filterMatrix(String id) {
  switch (id) {
    case 'mono':
      return saturationMatrix(0);
    case 'sepia':
      return <double>[
        0.393, 0.769, 0.189, 0, 0, //
        0.349, 0.686, 0.168, 0, 0,
        0.272, 0.534, 0.131, 0, 0,
        0, 0, 0, 1, 0,
      ];
    case 'vivid':
      return combineMatrix(contrastMatrix(0.15), saturationMatrix(1.45));
    case 'cool':
      return combineMatrix(warmthMatrix(-0.8), saturationMatrix(1.05));
    case 'warm':
      return combineMatrix(warmthMatrix(0.8), saturationMatrix(1.1));
    case 'fade':
      return <double>[
        0.85, 0, 0, 0, 30, //
        0, 0.85, 0, 0, 30,
        0, 0, 0.85, 0, 34,
        0, 0, 0, 1, 0,
      ];
    case 'vintage':
      return combineMatrix(
        <double>[0.9, 0.1, 0, 0, 18, 0.05, 0.85, 0.05, 0, 12, 0, 0.1, 0.7, 0, 8, 0, 0, 0, 1, 0],
        saturationMatrix(0.7),
      );
    default:
      return identityMatrix();
  }
}

/// Düzenleyicinin tüm ayarlarını tek matrise çevirir.
List<double> editMatrix({
  double brightness = 0,
  double contrast = 0,
  double saturation = 1,
  double warmth = 0,
  String filter = 'none',
}) {
  var m = filterMatrix(filter);
  m = combineMatrix(saturationMatrix(saturation), m);
  m = combineMatrix(warmthMatrix(warmth), m);
  m = combineMatrix(contrastMatrix(contrast), m);
  m = combineMatrix(brightnessMatrix(brightness), m);
  return m;
}

void applyMatrix(Rgba img, List<double> m) {
  final d = img.data;
  for (var i = 0; i < d.length; i += 4) {
    final r = d[i].toDouble(), g = d[i + 1].toDouble(), b = d[i + 2].toDouble(), a = d[i + 3].toDouble();
    d[i] = _c8(m[0] * r + m[1] * g + m[2] * b + m[3] * a + m[4]);
    d[i + 1] = _c8(m[5] * r + m[6] * g + m[7] * b + m[8] * a + m[9]);
    d[i + 2] = _c8(m[10] * r + m[11] * g + m[12] * b + m[13] * a + m[14]);
    d[i + 3] = _c8(m[15] * r + m[16] * g + m[17] * b + m[18] * a + m[19]);
  }
}

// --------------------------------------------------------------- filtreler

/// Keskinleştirme (3×3 maske), [amount] 0..1.
void sharpen(Rgba img, double amount) {
  if (amount <= 0) return;
  final w = img.width, h = img.height;
  final src = Uint8List.fromList(img.data);
  final d = img.data;
  final k = amount * 1.5;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final i = (y * w + x) * 4;
      for (var c = 0; c < 3; c++) {
        final center = src[i + c].toDouble();
        final n = src[i - 4 + c] + src[i + 4 + c] + src[i - w * 4 + c] + src[i + w * 4 + c];
        d[i + c] = _c8(center + k * (4 * center - n));
      }
    }
  }
}

/// Kenarları karartır, [amount] 0..1.
void vignette(Rgba img, double amount) {
  if (amount <= 0) return;
  final w = img.width, h = img.height;
  final cx = w / 2, cy = h / 2;
  final maxD = math.sqrt(cx * cx + cy * cy);
  final d = img.data;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final dx = x - cx, dy = y - cy;
      final r = math.sqrt(dx * dx + dy * dy) / maxD;
      final f = 1 - amount * math.pow(r, 2.2);
      final i = (y * w + x) * 4;
      d[i] = _c8(d[i] * f);
      d[i + 1] = _c8(d[i + 1] * f);
      d[i + 2] = _c8(d[i + 2] * f);
    }
  }
}

/// Çift doğrusal boyutlandırma.
Rgba resizeBilinear(Rgba src, int w, int h) {
  final out = Uint8List(w * h * 4);
  final sx = src.width / w, sy = src.height / h;
  for (var y = 0; y < h; y++) {
    final fy = math.max(0.0, (y + 0.5) * sy - 0.5);
    final y0 = math.min<int>(fy.floor(), src.height - 1);
    final y1 = math.min<int>(y0 + 1, src.height - 1);
    final ty = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = math.max(0.0, (x + 0.5) * sx - 0.5);
      final x0 = math.min<int>(fx.floor(), src.width - 1);
      final x1 = math.min<int>(x0 + 1, src.width - 1);
      final tx = fx - x0;
      final o = (y * w + x) * 4;
      for (var c = 0; c < 4; c++) {
        final a = src.data[(y0 * src.width + x0) * 4 + c] * (1 - tx) + src.data[(y0 * src.width + x1) * 4 + c] * tx;
        final b = src.data[(y1 * src.width + x0) * 4 + c] * (1 - tx) + src.data[(y1 * src.width + x1) * 4 + c] * tx;
        out[o + c] = _c8(a * (1 - ty) + b * ty);
      }
    }
  }
  return Rgba(w, h, out);
}

/// Dikdörtgen kırpma (sınırlar içine kırpılır).
Rgba cropRgba(Rgba src, int x, int y, int w, int h) {
  final x0 = x.clamp(0, src.width - 1), y0 = y.clamp(0, src.height - 1);
  final cw = math.max<int>(1, math.min<int>(w, src.width - x0));
  final ch = math.max<int>(1, math.min<int>(h, src.height - y0));
  final out = Uint8List(cw * ch * 4);
  for (var r = 0; r < ch; r++) {
    final s = ((y0 + r) * src.width + x0) * 4;
    out.setRange(r * cw * 4, (r + 1) * cw * 4, src.data, s);
  }
  return Rgba(cw, ch, out);
}

/// Bölgeyi bloklar halinde pikselleştirir.
void pixelate(Rgba img, int x, int y, int w, int h, int block) {
  final bs = math.max<int>(2, block);
  final x0 = x.clamp(0, img.width), y0 = y.clamp(0, img.height);
  final x1 = (x + w).clamp(0, img.width), y1 = (y + h).clamp(0, img.height);
  for (var by = y0; by < y1; by += bs) {
    for (var bx = x0; bx < x1; bx += bs) {
      final ex = math.min<int>(bx + bs, x1), ey = math.min<int>(by + bs, y1);
      var r = 0, g = 0, b = 0, n = 0;
      for (var yy = by; yy < ey; yy++) {
        for (var xx = bx; xx < ex; xx++) {
          final i = img.index(xx, yy);
          r += img.data[i];
          g += img.data[i + 1];
          b += img.data[i + 2];
          n++;
        }
      }
      if (n == 0) continue;
      for (var yy = by; yy < ey; yy++) {
        for (var xx = bx; xx < ex; xx++) {
          final i = img.index(xx, yy);
          img.data[i] = r ~/ n;
          img.data[i + 1] = g ~/ n;
          img.data[i + 2] = b ~/ n;
        }
      }
    }
  }
}

/// Bölgeyi güçlü biçimde bulanıklaştırır (küçült-büyüt + kutu bulanıklığı).
void blurRegion(Rgba img, int x, int y, int w, int h, {double strength = 0.6}) {
  final x0 = x.clamp(0, img.width - 1), y0 = y.clamp(0, img.height - 1);
  final rw = math.max<int>(1, math.min<int>(w, img.width - x0));
  final rh = math.max<int>(1, math.min<int>(h, img.height - y0));
  final region = cropRgba(img, x0, y0, rw, rh);
  final f = (4 + strength * 28).round();
  final small = resizeBilinear(region, math.max<int>(1, rw ~/ f), math.max<int>(1, rh ~/ f));
  final back = resizeBilinear(small, rw, rh);
  for (var r = 0; r < rh; r++) {
    for (var c = 0; c < rw; c++) {
      final s = (r * rw + c) * 4;
      final dI = img.index(x0 + c, y0 + r);
      img.data[dI] = back.data[s];
      img.data[dI + 1] = back.data[s + 1];
      img.data[dI + 2] = back.data[s + 2];
    }
  }
}

// --------------------------------------------------------------- kırpma oranı

/// Ortalanmış en büyük [ratio] (genişlik/yükseklik) dikdörtgeni.
({int x, int y, int w, int h}) centeredCrop(int w, int h, double ratio) {
  if (ratio <= 0) return (x: 0, y: 0, w: w, h: h);
  if (w / h > ratio) {
    final nw = (h * ratio).round();
    return (x: (w - nw) ~/ 2, y: 0, w: nw, h: h);
  }
  final nh = (w / ratio).round();
  return (x: 0, y: (h - nh) ~/ 2, w: w, h: nh);
}

/// En uzun kenarı [maxSide] olacak şekilde ölçek.
({int w, int h}) fitWithin(int w, int h, int maxSide) {
  final m = math.max<int>(w, h);
  if (m <= maxSide) return (w: w, h: h);
  final s = maxSide / m;
  return (w: math.max<int>(1, (w * s).round()), h: math.max<int>(1, (h * s).round()));
}

// --------------------------------------------------------------- dHash

/// 64 bitlik fark karması (8 bayt). Benzer fotoğraflarda küçük Hamming mesafesi.
Uint8List dHash(Rgba img) {
  final small = resizeBilinear(img, 9, 8);
  final gray = List<double>.generate(72, (i) {
    final o = i * 4;
    return 0.299 * small.data[o] + 0.587 * small.data[o + 1] + 0.114 * small.data[o + 2];
  });
  final out = Uint8List(8);
  for (var y = 0; y < 8; y++) {
    var byte = 0;
    for (var x = 0; x < 8; x++) {
      if (gray[y * 9 + x] > gray[y * 9 + x + 1]) byte |= 1 << x;
    }
    out[y] = byte;
  }
  return out;
}

int hamming(Uint8List a, Uint8List b) {
  var n = 0;
  for (var i = 0; i < math.min<int>(a.length, b.length); i++) {
    var v = a[i] ^ b[i];
    while (v != 0) {
      n += v & 1;
      v >>= 1;
    }
  }
  return n;
}

/// Mesafesi ≤ [threshold] olanları gruplar; yalnızca 2+ üyeli gruplar döner.
List<List<int>> groupSimilar(List<Uint8List> hashes, int threshold) {
  final parent = List<int>.generate(hashes.length, (i) => i);
  int find(int i) {
    while (parent[i] != i) {
      parent[i] = parent[parent[i]];
      i = parent[i];
    }
    return i;
  }

  for (var i = 0; i < hashes.length; i++) {
    for (var j = i + 1; j < hashes.length; j++) {
      if (hamming(hashes[i], hashes[j]) <= threshold) {
        final a = find(i), b = find(j);
        if (a != b) parent[b] = a;
      }
    }
  }
  final groups = <int, List<int>>{};
  for (var i = 0; i < hashes.length; i++) {
    groups.putIfAbsent(find(i), () => <int>[]).add(i);
  }
  return groups.values.where((g) => g.length > 1).toList();
}

// --------------------------------------------------------------- kolaj

/// Birim kare içinde hücreler [x, y, w, h]. [variant] aynı sayı için farklı düzen.
List<List<double>> collageCells(int count, int variant) {
  final n = count.clamp(1, 9);
  final v = variant % 3;
  List<List<double>> grid(int cols, int rows) => [
        for (var r = 0; r < rows; r++)
          for (var c = 0; c < cols; c++) [c / cols, r / rows, 1 / cols, 1 / rows],
      ];
  switch (n) {
    case 1:
      return [
        [0, 0, 1, 1]
      ];
    case 2:
      return v == 1 ? grid(1, 2) : grid(2, 1);
    case 3:
      if (v == 0) {
        return [
          [0, 0, 0.5, 1],
          [0.5, 0, 0.5, 0.5],
          [0.5, 0.5, 0.5, 0.5]
        ];
      }
      if (v == 1) {
        return [
          [0, 0, 1, 0.5],
          [0, 0.5, 0.5, 0.5],
          [0.5, 0.5, 0.5, 0.5]
        ];
      }
      return grid(3, 1);
    case 4:
      if (v == 1) {
        return [
          [0, 0, 1, 0.6],
          [0, 0.6, 1 / 3, 0.4],
          [1 / 3, 0.6, 1 / 3, 0.4],
          [2 / 3, 0.6, 1 / 3, 0.4]
        ];
      }
      return v == 2 ? grid(4, 1) : grid(2, 2);
    case 5:
      return [
        [0, 0, 0.5, 0.5],
        [0.5, 0, 0.5, 0.5],
        [0, 0.5, 1 / 3, 0.5],
        [1 / 3, 0.5, 1 / 3, 0.5],
        [2 / 3, 0.5, 1 / 3, 0.5]
      ];
    case 6:
      return v == 1 ? grid(2, 3) : grid(3, 2);
    default:
      final cols = 3, rows = (n / 3).ceil();
      return grid(cols, rows).take(n).toList();
  }
}

// --------------------------------------------------------------- U²-Netp

const int kU2Size = 320;

/// U²-Netp girdisi: 1×3×320×320, ImageNet ortalaması ve sapmasıyla.
Float32List u2Input(Rgba src) {
  final r = resizeBilinear(src, kU2Size, kU2Size);
  const mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225];
  var maxV = 1.0;
  for (var i = 0; i < r.data.length; i += 4) {
    maxV = math.max(maxV, math.max(r.data[i], math.max(r.data[i + 1], r.data[i + 2])).toDouble());
  }
  final plane = kU2Size * kU2Size;
  final out = Float32List(3 * plane);
  for (var p = 0; p < plane; p++) {
    for (var c = 0; c < 3; c++) {
      out[c * plane + p] = (r.data[p * 4 + c] / maxV - mean[c]) / std[c];
    }
  }
  return out;
}

/// Model çıktısını 0..255 maskeye çevirir (min-maks normalizasyonu).
Uint8List u2Mask(Float32List out) {
  var lo = double.infinity, hi = -double.infinity;
  for (final v in out) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  final span = (hi - lo) < 1e-6 ? 1.0 : hi - lo;
  return Uint8List.fromList([for (final v in out) _c8((v - lo) / span * 255)]);
}

/// Maskeyi (mw×mh) görüntü boyutuna büyütüp alfa kanalına yazar.
void applyMask(Rgba img, Uint8List mask, int mw, int mh) {
  final m = Rgba(mw, mh, Uint8List(mw * mh * 4));
  for (var i = 0; i < mw * mh; i++) {
    m.data[i * 4] = mask[i];
    m.data[i * 4 + 3] = 255;
  }
  final big = resizeBilinear(m, img.width, img.height);
  for (var i = 0; i < img.width * img.height; i++) {
    img.data[i * 4 + 3] = big.data[i * 4];
  }
}

// --------------------------------------------------------------- Real-ESRGAN

/// Düzlemsel 1×3×H×W, 0..1.
Float32List rgbPlanar(Rgba img) {
  final plane = img.width * img.height;
  final out = Float32List(3 * plane);
  for (var p = 0; p < plane; p++) {
    for (var c = 0; c < 3; c++) {
      out[c * plane + p] = img.data[p * 4 + c] / 255.0;
    }
  }
  return out;
}

Rgba fromPlanar(Float32List data, int w, int h) {
  final plane = w * h;
  final out = Uint8List(plane * 4);
  for (var p = 0; p < plane; p++) {
    for (var c = 0; c < 3; c++) {
      out[p * 4 + c] = _c8(data[c * plane + p] * 255);
    }
    out[p * 4 + 3] = 255;
  }
  return Rgba(w, h, out);
}

/// Görüntüyü üst üste binen karolara böler: (x, y, w, h).
List<({int x, int y, int w, int h})> tiles(int width, int height, int tile, int overlap) {
  final out = <({int x, int y, int w, int h})>[];
  final step = math.max<int>(1, tile - 2 * overlap);
  for (var y = 0; y < height; y += step) {
    for (var x = 0; x < width; x += step) {
      final x0 = math.max<int>(0, x - overlap), y0 = math.max<int>(0, y - overlap);
      final x1 = math.min<int>(width, x + step + overlap), y1 = math.min<int>(height, y + step + overlap);
      out.add((x: x0, y: y0, w: x1 - x0, h: y1 - y0));
    }
  }
  return out;
}

/// Ölçeklenmiş karonun, çakışma payı atılmış kısmını hedefe yazar.
void pasteTile(Rgba dst, Rgba tile, ({int x, int y, int w, int h}) t, int scale, int overlap, int step) {
  final ix = t.x == 0 ? 0 : overlap;
  final iy = t.y == 0 ? 0 : overlap;
  final cx = (t.x + ix);
  final cy = (t.y + iy);
  final cw = math.min<int>(step, (dst.width ~/ scale) - cx);
  final ch = math.min<int>(step, (dst.height ~/ scale) - cy);
  for (var r = 0; r < ch * scale; r++) {
    final sy = iy * scale + r;
    if (sy >= tile.height) break;
    final dy = cy * scale + r;
    final w = math.min<int>(cw * scale, tile.width - ix * scale);
    if (w <= 0) continue;
    dst.data.setRange((dy * dst.width + cx * scale) * 4, (dy * dst.width + cx * scale + w) * 4, tile.data,
        (sy * tile.width + ix * scale) * 4);
  }
}

// --------------------------------------------------------------- Lab (renklendirme)

double _lin(double c) {
  c /= 255;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _gam(double c) {
  final v = c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
  return v * 255;
}

double _f(double t) => t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;

double _fi(double t) => t > 0.206893 ? t * t * t : (t - 16 / 116) / 7.787;

/// sRGB → CIELAB (D65).
(double, double, double) rgbToLab(int r, int g, int b) {
  final lr = _lin(r.toDouble()), lg = _lin(g.toDouble()), lb = _lin(b.toDouble());
  final x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047;
  final y = (0.2126 * lr + 0.7152 * lg + 0.0722 * lb);
  final z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883;
  final fx = _f(x), fy = _f(y), fz = _f(z);
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

(int, int, int) labToRgb(double l, double a, double bb) {
  final fy = (l + 16) / 116;
  final fx = fy + a / 500;
  final fz = fy - bb / 200;
  final x = _fi(fx) * 0.95047, y = _fi(fy), z = _fi(fz) * 1.08883;
  final r = 3.2406 * x - 1.5372 * y - 0.4986 * z;
  final g = -0.9689 * x + 1.8758 * y + 0.0415 * z;
  final b = 0.0557 * x - 0.2040 * y + 1.0570 * z;
  return (_c8(_gam(r)), _c8(_gam(g)), _c8(_gam(b)));
}

const int kColorSize = 256;

/// ECCV16 girdisi: 256×256 L kanalı (0..100).
Float32List lightnessInput(Rgba src) {
  final r = resizeBilinear(src, kColorSize, kColorSize);
  final out = Float32List(kColorSize * kColorSize);
  for (var p = 0; p < out.length; p++) {
    out[p] = rgbToLab(r.data[p * 4], r.data[p * 4 + 1], r.data[p * 4 + 2]).$1;
  }
  return out;
}

/// Özgün L ile modelin ab çıktısını (2×256×256) birleştirir.
Rgba combineLab(Rgba orig, Float32List ab) {
  const s = kColorSize;
  final abImg = Rgba(s, s, Uint8List(s * s * 4));
  for (var p = 0; p < s * s; p++) {
    abImg.data[p * 4] = _c8(ab[p] + 128);
    abImg.data[p * 4 + 1] = _c8(ab[s * s + p] + 128);
    abImg.data[p * 4 + 3] = 255;
  }
  final big = resizeBilinear(abImg, orig.width, orig.height);
  final out = orig.copy();
  for (var p = 0; p < orig.width * orig.height; p++) {
    final lab = rgbToLab(orig.data[p * 4], orig.data[p * 4 + 1], orig.data[p * 4 + 2]);
    final rgb = labToRgb(lab.$1, big.data[p * 4] - 128.0, big.data[p * 4 + 1] - 128.0);
    out.data[p * 4] = rgb.$1;
    out.data[p * 4 + 1] = rgb.$2;
    out.data[p * 4 + 2] = rgb.$3;
  }
  return out;
}

// --------------------------------------------------------------- duvar kağıdı

/// Tohumdan tekrarlanabilir renk paleti (3 renk, ARGB).
List<int> paletteFromSeed(int seed) {
  final rnd = math.Random(seed);
  final baseHue = rnd.nextDouble() * 360;
  int hsl(double h, double s, double l) {
    final c = (1 - (2 * l - 1).abs()) * s;
    final hp = (h % 360) / 60;
    final x = c * (1 - (hp % 2 - 1).abs());
    var r = 0.0, g = 0.0, b = 0.0;
    if (hp < 1) {
      r = c;
      g = x;
    } else if (hp < 2) {
      r = x;
      g = c;
    } else if (hp < 3) {
      g = c;
      b = x;
    } else if (hp < 4) {
      g = x;
      b = c;
    } else if (hp < 5) {
      r = x;
      b = c;
    } else {
      r = c;
      b = x;
    }
    final m = l - c / 2;
    return 0xFF000000 | (_c8((r + m) * 255) << 16) | (_c8((g + m) * 255) << 8) | _c8((b + m) * 255);
  }

  return [
    hsl(baseHue, 0.65, 0.35),
    hsl(baseHue + 40 + rnd.nextDouble() * 40, 0.7, 0.55),
    hsl(baseHue + 180 + rnd.nextDouble() * 60, 0.6, 0.7),
  ];
}

// --------------------------------------------------------------- plaka

/// Plaka benzeri metin: 5–10 karakter, hem harf hem rakam içerir.
bool looksLikePlate(String text) {
  final s = text.replaceAll(RegExp(r'[\s\-·.]'), '').toUpperCase();
  if (s.length < 5 || s.length > 10) return false;
  if (!RegExp(r'^[A-Z0-9]+$').hasMatch(s)) return false;
  return RegExp(r'[A-Z]').hasMatch(s) && RegExp(r'[0-9]').hasMatch(s);
}
