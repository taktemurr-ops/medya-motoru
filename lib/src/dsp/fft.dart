/// Yerinde, ikinin kuvveti uzunlukta karmaşık FFT (Cooley–Tukey).
library;

import 'dart:math' as math;
import 'dart:typed_data';

void fft(Float64List re, Float64List im) => _transform(re, im, false);

/// Ters dönüşüm (1/N ölçekli).
void ifft(Float64List re, Float64List im) {
  _transform(re, im, true);
  final n = re.length;
  for (var i = 0; i < n; i++) {
    re[i] /= n;
    im[i] /= n;
  }
}

void _transform(Float64List re, Float64List im, bool inverse) {
  final n = re.length;
  assert(n > 0 && (n & (n - 1)) == 0, 'length must be a power of two');
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; (j & bit) != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = 2 * math.pi / len * (inverse ? 1 : -1);
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final a = i + k, b = i + k + len ~/ 2;
        final xr = re[b] * cr - im[b] * ci;
        final xi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
        final nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}
