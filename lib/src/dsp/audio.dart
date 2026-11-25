/// Saf Dart ses işlemleri: WAV okuma/yazma, kesme, yumuşak geçiş, seviye,
/// gürültü üreteçleri, davul ve nota sentezi, ses efektleri, spektral
/// gürültü azaltma, ritim dizicisi ve SRT biçimi. Web dahil her yerde çalışır.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

/// Kayan noktalı PCM ses (-1..1, kanallar iç içe).
class Pcm {
  final int rate;
  final int channels;
  final Float32List samples;

  Pcm(this.rate, this.channels, this.samples);

  factory Pcm.silence(int rate, double seconds, {int channels = 1}) =>
      Pcm(rate, channels, Float32List((rate * seconds).round() * channels));

  int get frames => samples.length ~/ channels;
  double get seconds => frames / rate;

  Pcm copy() => Pcm(rate, channels, Float32List.fromList(samples));
}

// --------------------------------------------------------------------- WAV

Uint8List encodeWav(Pcm p) {
  final n = p.samples.length;
  final b = ByteData(44 + n * 2);
  void s(int o, String t) {
    for (var i = 0; i < t.length; i++) {
      b.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  b.setUint32(4, 36 + n * 2, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, p.channels, Endian.little);
  b.setUint32(24, p.rate, Endian.little);
  b.setUint32(28, p.rate * p.channels * 2, Endian.little);
  b.setUint16(32, p.channels * 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  s(36, 'data');
  b.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = p.samples[i].clamp(-1.0, 1.0);
    b.setInt16(44 + i * 2, (v * 32767).round(), Endian.little);
  }
  return b.buffer.asUint8List();
}

/// PCM (8/16/24/32 bit tam sayı) ve 32 bit kayan noktalı WAV okur.
Pcm? decodeWav(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final b = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  var o = 12;
  var fmt = 0, ch = 1, rate = 44100, bits = 16;
  int? dataOff, dataLen;
  while (o + 8 <= bytes.length) {
    final id = tag(o);
    final len = b.getUint32(o + 4, Endian.little);
    if (id == 'fmt ') {
      fmt = b.getUint16(o + 8, Endian.little);
      ch = b.getUint16(o + 10, Endian.little);
      rate = b.getUint32(o + 12, Endian.little);
      bits = b.getUint16(o + 22, Endian.little);
      if (fmt == 0xFFFE && len >= 26) fmt = b.getUint16(o + 32, Endian.little);
    } else if (id == 'data') {
      dataOff = o + 8;
      dataLen = math.min<int>(len, bytes.length - dataOff);
      break;
    }
    o += 8 + len + (len & 1);
  }
  if (dataOff == null || dataLen == null || ch < 1) return null;
  final bps = bits ~/ 8;
  if (bps < 1) return null;
  final n = dataLen ~/ bps;
  final out = Float32List(n - n % ch);
  for (var i = 0; i < out.length; i++) {
    final p = dataOff + i * bps;
    double v;
    if (fmt == 3 && bits == 32) {
      v = b.getFloat32(p, Endian.little);
    } else if (bits == 8) {
      v = (b.getUint8(p) - 128) / 128;
    } else if (bits == 16) {
      v = b.getInt16(p, Endian.little) / 32768;
    } else if (bits == 24) {
      var x = b.getUint8(p) | (b.getUint8(p + 1) << 8) | (b.getUint8(p + 2) << 16);
      if (x & 0x800000 != 0) x -= 0x1000000;
      v = x / 8388608;
    } else if (bits == 32) {
      v = b.getInt32(p, Endian.little) / 2147483648;
    } else {
      return null;
    }
    out[i] = v;
  }
  return Pcm(rate, ch, out);
}

// --------------------------------------------------------------------- düzenleme

Pcm toMono(Pcm p) {
  if (p.channels == 1) return p;
  final out = Float32List(p.frames);
  for (var f = 0; f < p.frames; f++) {
    var s = 0.0;
    for (var c = 0; c < p.channels; c++) {
      s += p.samples[f * p.channels + c];
    }
    out[f] = s / p.channels;
  }
  return Pcm(p.rate, 1, out);
}

Pcm trimPcm(Pcm p, double startSec, double endSec) {
  final a = (startSec * p.rate).round().clamp(0, p.frames);
  final b = (endSec * p.rate).round().clamp(a, p.frames);
  return Pcm(p.rate, p.channels, Float32List.fromList(p.samples.sublist(a * p.channels, b * p.channels)));
}

void fadeIn(Pcm p, double sec) {
  final n = math.min<int>((sec * p.rate).round(), p.frames);
  for (var f = 0; f < n; f++) {
    final g = f / n;
    for (var c = 0; c < p.channels; c++) {
      p.samples[f * p.channels + c] *= g;
    }
  }
}

void fadeOut(Pcm p, double sec) {
  final n = math.min<int>((sec * p.rate).round(), p.frames);
  for (var i = 0; i < n; i++) {
    final f = p.frames - 1 - i;
    final g = i / n;
    for (var c = 0; c < p.channels; c++) {
      p.samples[f * p.channels + c] *= g;
    }
  }
}

double dbToGain(double db) => math.pow(10, db / 20).toDouble();

void applyGain(Pcm p, double db) {
  final g = dbToGain(db);
  for (var i = 0; i < p.samples.length; i++) {
    p.samples[i] *= g;
  }
}

double peakOf(Pcm p) {
  var m = 0.0;
  for (final v in p.samples) {
    final a = v.abs();
    if (a > m) m = a;
  }
  return m;
}

double rmsOf(Pcm p) {
  if (p.samples.isEmpty) return 0;
  var s = 0.0;
  for (final v in p.samples) {
    s += v * v;
  }
  return math.sqrt(s / p.samples.length);
}

/// Tepe seviyesini [targetDb] (ör. -1 dBFS) yapar.
void normalizePeak(Pcm p, {double targetDb = -1}) {
  final pk = peakOf(p);
  if (pk < 1e-6) return;
  final g = dbToGain(targetDb) / pk;
  for (var i = 0; i < p.samples.length; i++) {
    p.samples[i] *= g;
  }
}

Pcm reversePcm(Pcm p) {
  final out = Float32List(p.samples.length);
  for (var f = 0; f < p.frames; f++) {
    for (var c = 0; c < p.channels; c++) {
      out[f * p.channels + c] = p.samples[(p.frames - 1 - f) * p.channels + c];
    }
  }
  return Pcm(p.rate, p.channels, out);
}

/// Yumuşak sınırlayıcı: kırpılmayı önler.
void softLimit(Pcm p, {double ceiling = 0.98}) {
  for (var i = 0; i < p.samples.length; i++) {
    final v = p.samples[i];
    final a = v.abs();
    if (a > 0.7) {
      final over = (a - 0.7) / (ceiling - 0.7 + 1e-9);
      final y = 0.7 + (ceiling - 0.7) * (1 - math.exp(-over));
      p.samples[i] = v < 0 ? -y : y;
    }
  }
}

/// Ses yükseltici: önce RMS'i hedefe taşır, sonra sınırlar.
void boost(Pcm p, double db) {
  applyGain(p, db);
  softLimit(p);
}

/// Dalga biçimi çizimi için [n] tepe değeri.
List<double> peaks(Pcm p, int n) {
  if (p.frames == 0 || n <= 0) return List<double>.filled(math.max<int>(0, n), 0);
  final per = math.max<int>(1, p.frames ~/ n);
  return List<double>.generate(n, (i) {
    var m = 0.0;
    final a = i * per;
    final b = math.min<int>(p.frames, a + per);
    for (var f = a; f < b; f++) {
      final v = p.samples[f * p.channels].abs();
      if (v > m) m = v;
    }
    return m;
  });
}

/// Doğrusal örnekleme hızı dönüşümü.
Pcm resample(Pcm p, int rate) {
  if (rate == p.rate) return p;
  final frames = (p.frames * rate / p.rate).round();
  final out = Float32List(frames * p.channels);
  for (var f = 0; f < frames; f++) {
    final pos = f * p.rate / rate;
    final a = pos.floor().clamp(0, p.frames - 1);
    final b = math.min<int>(a + 1, p.frames - 1);
    final t = pos - a;
    for (var c = 0; c < p.channels; c++) {
      out[f * p.channels + c] = p.samples[a * p.channels + c] * (1 - t) + p.samples[b * p.channels + c] * t;
    }
  }
  return Pcm(rate, p.channels, out);
}

/// İki sesi uç uca ekler (oran ve kanal uyumlu olmalı).
Pcm concatPcm(Pcm a, Pcm b) {
  final out = Float32List(a.samples.length + b.samples.length)
    ..setRange(0, a.samples.length, a.samples)
    ..setRange(a.samples.length, a.samples.length + b.samples.length, b.samples);
  return Pcm(a.rate, a.channels, out);
}

// --------------------------------------------------------------------- filtreler

/// İkinci dereceden filtre (RBJ).
class Biquad {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  Biquad.lowpass(double rate, double freq, {double q = 0.707}) {
    _set(rate, freq, q, 0);
  }

  Biquad.highpass(double rate, double freq, {double q = 0.707}) {
    _set(rate, freq, q, 1);
  }

  Biquad.bandpass(double rate, double freq, {double q = 1}) {
    _set(rate, freq, q, 2);
  }

  void _set(double rate, double freq, double q, int kind) {
    final w = 2 * math.pi * freq.clamp(10.0, rate / 2 - 10) / rate;
    final cw = math.cos(w), sw = math.sin(w);
    final alpha = sw / (2 * q);
    double nb0, nb1, nb2;
    if (kind == 0) {
      nb0 = (1 - cw) / 2;
      nb1 = 1 - cw;
      nb2 = (1 - cw) / 2;
    } else if (kind == 1) {
      nb0 = (1 + cw) / 2;
      nb1 = -(1 + cw);
      nb2 = (1 + cw) / 2;
    } else {
      nb0 = alpha;
      nb1 = 0;
      nb2 = -alpha;
    }
    final a0 = 1 + alpha;
    b0 = nb0 / a0;
    b1 = nb1 / a0;
    b2 = nb2 / a0;
    a1 = -2 * cw / a0;
    a2 = (1 - alpha) / a0;
  }

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

// --------------------------------------------------------------------- gürültü

const List<String> kNoiseIds = ['white', 'pink', 'brown', 'rain', 'waves', 'fan', 'wind'];

/// Döngüye uygun ortam sesi (sonu başa yumuşakça bağlanır).
Pcm ambient(String kind, {double seconds = 12, int rate = 22050, int seed = 7}) {
  final rnd = math.Random(seed);
  final n = (seconds * rate).round();
  final out = Float32List(n);
  var b0 = 0.0, b1 = 0.0, b2 = 0.0, b3 = 0.0, b4 = 0.0, b5 = 0.0, b6 = 0.0;
  var brown = 0.0;
  double pink(double w) {
    b0 = 0.99886 * b0 + w * 0.0555179;
    b1 = 0.99332 * b1 + w * 0.0750759;
    b2 = 0.96900 * b2 + w * 0.1538520;
    b3 = 0.86650 * b3 + w * 0.3104856;
    b4 = 0.55000 * b4 + w * 0.5329522;
    b5 = -0.7616 * b5 - w * 0.0168980;
    final y = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362;
    b6 = w * 0.115926;
    return y * 0.11;
  }

  final lp = Biquad.lowpass(rate.toDouble(), 900);
  final lp2 = Biquad.lowpass(rate.toDouble(), 2500);
  final bp = Biquad.bandpass(rate.toDouble(), 500, q: 0.8);
  final hp = Biquad.highpass(rate.toDouble(), 1500);
  var drop = 0.0;
  for (var i = 0; i < n; i++) {
    final w = rnd.nextDouble() * 2 - 1;
    final t = i / rate;
    double v;
    switch (kind) {
      case 'pink':
        v = pink(w);
        break;
      case 'brown':
        brown = (brown + 0.02 * w) / 1.02;
        v = brown * 3.5;
        break;
      case 'rain':
        if (rnd.nextDouble() < 0.0015) drop = 0.6 + rnd.nextDouble() * 0.4;
        drop *= 0.9;
        v = lp2.process(pink(w)) * 0.8 + hp.process(w) * drop * 0.5;
        break;
      case 'waves':
        brown = (brown + 0.02 * w) / 1.02;
        final swell = 0.35 + 0.65 * math.pow(0.5 + 0.5 * math.sin(2 * math.pi * t / 6.0), 2).toDouble();
        v = lp.process(brown * 3.5 + pink(w) * 0.5) * swell * 1.6;
        break;
      case 'fan':
        v = lp.process(pink(w)) * 1.4 + 0.04 * math.sin(2 * math.pi * 100 * t);
        break;
      case 'wind':
        final gust = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(2 * math.pi * t / 4.0 + math.sin(t)));
        v = bp.process(pink(w)) * gust * 2.4;
        break;
      default:
        v = w * 0.35;
    }
    out[i] = v;
  }
  // Döngü dikişi: son 0,5 sn başa karışır.
  final x = math.min<int>(n ~/ 4, rate ~/ 2);
  for (var i = 0; i < x; i++) {
    final g = i / x;
    out[i] = out[i] * g + out[n - x + i] * (1 - g);
  }
  final p = Pcm(rate, 1, Float32List.fromList(out.sublist(0, n - x)));
  normalizePeak(p, targetDb: -3);
  return p;
}

/// Birden çok sesi seviyeleriyle karıştırır (uzunluk: en uzun).
Pcm mix(List<Pcm> parts, List<double> levels) {
  if (parts.isEmpty) return Pcm.silence(22050, 1);
  final rate = parts.first.rate;
  final n = parts.map((p) => p.frames).reduce(math.max);
  final out = Float32List(n);
  for (var k = 0; k < parts.length; k++) {
    final p = toMono(parts[k]);
    final g = k < levels.length ? levels[k] : 1.0;
    for (var i = 0; i < n; i++) {
      out[i] += p.samples[i % math.max<int>(1, p.frames)] * g;
    }
  }
  final r = Pcm(rate, 1, out);
  if (peakOf(r) > 0.98) normalizePeak(r, targetDb: -1);
  return r;
}

// --------------------------------------------------------------------- davul

const List<String> kDrumIds = ['kick', 'snare', 'hat', 'clap', 'tom', 'rim', 'crash', 'shaker'];

Pcm drum(String kind, {int rate = 44100}) {
  final rnd = math.Random(kind.hashCode & 0xffff);
  double len;
  switch (kind) {
    case 'crash':
      len = 1.6;
      break;
    case 'kick':
    case 'tom':
      len = 0.45;
      break;
    case 'snare':
    case 'clap':
      len = 0.3;
      break;
    default:
      len = 0.12;
  }
  final n = (len * rate).round();
  final out = Float32List(n);
  final hp = Biquad.highpass(rate.toDouble(), 7000);
  final hp2 = Biquad.highpass(rate.toDouble(), 5000);
  final bp = Biquad.bandpass(rate.toDouble(), 1200, q: 0.9);
  var phase = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    final w = rnd.nextDouble() * 2 - 1;
    double v;
    switch (kind) {
      case 'kick':
        final f = 45 + 110 * math.exp(-t * 30);
        phase += 2 * math.pi * f / rate;
        v = math.sin(phase) * math.exp(-t * 7) + (t < 0.004 ? w * 0.4 : 0);
        break;
      case 'tom':
        final ft = 110 + 120 * math.exp(-t * 15);
        phase += 2 * math.pi * ft / rate;
        v = math.sin(phase) * math.exp(-t * 8);
        break;
      case 'snare':
        phase += 2 * math.pi * 185 / rate;
        v = math.sin(phase) * math.exp(-t * 25) * 0.5 + hp2.process(w) * math.exp(-t * 14) * 0.9;
        break;
      case 'clap':
        final burst = (t < 0.01 || (t > 0.012 && t < 0.02) || (t > 0.024 && t < 0.032)) ? 1.0 : 0.0;
        v = bp.process(w) * (burst + math.exp(-(t - 0.03).abs() * 18) * 0.6) * 1.8;
        break;
      case 'rim':
        phase += 2 * math.pi * 1700 / rate;
        v = math.sin(phase) * math.exp(-t * 90) + w * math.exp(-t * 200) * 0.3;
        break;
      case 'crash':
        v = hp2.process(w) * math.exp(-t * 2.2) * 0.8;
        break;
      case 'shaker':
        v = hp.process(w) * math.sin(math.pi * math.min(1.0, t / len)) * 0.8;
        break;
      default: // hat
        v = hp.process(w) * math.exp(-t * 60);
    }
    out[i] = v;
  }
  final p = Pcm(rate, 1, out);
  normalizePeak(p, targetDb: -2);
  return p;
}

// --------------------------------------------------------------------- notalar

double midiFreq(int midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();

/// Piyano benzeri nota (toplamsal harmonikler, üstel sönüm).
Pcm pianoNote(int midi, {int rate = 44100, double seconds = 1.6}) {
  final f = midiFreq(midi);
  final n = (seconds * rate).round();
  final out = Float32List(n);
  const amps = [1.0, 0.5, 0.28, 0.16, 0.09, 0.05];
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    var v = 0.0;
    for (var h = 0; h < amps.length; h++) {
      final fh = f * (h + 1) * (1 + 0.0004 * h * h);
      if (fh > rate / 2) break;
      v += amps[h] * math.sin(2 * math.pi * fh * t) * math.exp(-t * (2.2 + h * 0.9));
    }
    final attack = math.min(1.0, t / 0.004);
    out[i] = v * attack * 0.35;
  }
  return Pcm(rate, 1, out);
}

/// Sentezleyici sesi.
class SynthPatch {
  final String wave;
  final double attack, decay, sustain, release, cutoff;
  const SynthPatch({
    this.wave = 'saw',
    this.attack = 0.01,
    this.decay = 0.2,
    this.sustain = 0.6,
    this.release = 0.3,
    this.cutoff = 3000,
  });
}

const List<String> kWaveIds = ['sine', 'square', 'saw', 'triangle'];

double _osc(String wave, double ph) {
  final x = ph - ph.floor();
  switch (wave) {
    case 'square':
      return x < 0.5 ? 0.8 : -0.8;
    case 'saw':
      return 2 * x - 1;
    case 'triangle':
      return 1 - 4 * (x - 0.5).abs();
    default:
      return math.sin(2 * math.pi * x);
  }
}

/// [hold] saniye basılı tutulan bir nota (ADSR + alçak geçiren filtre).
Pcm synthNote(int midi, SynthPatch p, {int rate = 44100, double hold = 0.5}) {
  final f = midiFreq(midi);
  final total = hold + p.release;
  final n = (total * rate).round();
  final out = Float32List(n);
  final lp = Biquad.lowpass(rate.toDouble(), p.cutoff, q: 0.9);
  var ph = 0.0;
  for (var i = 0; i < n; i++) {
    final t = i / rate;
    double env;
    if (t < p.attack) {
      env = t / math.max(1e-4, p.attack);
    } else if (t < p.attack + p.decay) {
      env = 1 - (1 - p.sustain) * (t - p.attack) / math.max(1e-4, p.decay);
    } else if (t < hold) {
      env = p.sustain;
    } else {
      env = p.sustain * (1 - (t - hold) / math.max(1e-4, p.release));
    }
    ph += f / rate;
    out[i] = lp.process(_osc(p.wave, ph)) * env.clamp(0.0, 1.0) * 0.4;
  }
  return Pcm(rate, 1, out);
}

// --------------------------------------------------------------------- ses efektleri

const List<String> kVoiceIds = ['robot', 'chipmunk', 'giant', 'echo', 'cave', 'radio'];

/// Süreyi koruyarak perdeyi değiştirir (taneli örtüşmeli ekleme).
Pcm pitchShift(Pcm mono, double ratio) {
  final rate = mono.rate;
  final grain = (0.05 * rate).round();
  final hop = grain ~/ 4;
  final n = mono.frames;
  final out = Float32List(n);
  final norm = Float32List(n);
  final win = Float32List.fromList(List<double>.generate(grain, (i) => 0.5 - 0.5 * math.cos(2 * math.pi * i / grain)));
  for (var start = 0; start + grain < n; start += hop) {
    for (var i = 0; i < grain; i++) {
      final src = start + i * ratio;
      final a = src.floor();
      if (a + 1 >= n) break;
      final t = src - a;
      final v = mono.samples[a] * (1 - t) + mono.samples[a + 1] * t;
      out[start + i] += v * win[i];
      norm[start + i] += win[i];
    }
  }
  for (var i = 0; i < n; i++) {
    if (norm[i] > 1e-3) out[i] /= norm[i];
  }
  return Pcm(rate, 1, out);
}

Pcm _delay(Pcm mono, double sec, double feedback, double wet) {
  final d = math.max<int>(1, (sec * mono.rate).round());
  final n = mono.frames + d * 4;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final dry = i < mono.frames ? mono.samples[i] : 0.0;
    final back = i >= d ? out[i - d] : 0.0;
    out[i] = dry + back * feedback;
  }
  for (var i = 0; i < n; i++) {
    final dry = i < mono.frames ? mono.samples[i] : 0.0;
    out[i] = dry * (1 - wet) + out[i] * wet;
  }
  return Pcm(mono.rate, 1, out);
}

/// Schroeder yankısı (4 tarak + 2 tüm geçiren).
Pcm reverb(Pcm mono, {double size = 1.0, double wet = 0.45}) {
  final r = mono.rate;
  final tail = (1.5 * size * r).round();
  final n = mono.frames + tail;
  final input = Float32List(n)..setRange(0, mono.frames, mono.samples);
  final acc = Float32List(n);
  for (final ms in [29.7, 37.1, 41.1, 43.7]) {
    final d = (ms * size / 1000 * r).round();
    final buf = Float32List(n);
    for (var i = 0; i < n; i++) {
      buf[i] = input[i] + (i >= d ? buf[i - d] * 0.78 : 0.0);
      acc[i] += buf[i] * 0.25;
    }
  }
  var x = acc;
  for (final ms in [5.0, 1.7]) {
    final d = (ms / 1000 * r).round();
    final y = Float32List(n);
    for (var i = 0; i < n; i++) {
      final xd = i >= d ? x[i - d] : 0.0;
      final yd = i >= d ? y[i - d] : 0.0;
      y[i] = -0.7 * x[i] + xd + 0.7 * yd;
    }
    x = y;
  }
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = input[i] * (1 - wet) + x[i] * wet;
  }
  final p = Pcm(r, 1, out);
  if (peakOf(p) > 0.98) normalizePeak(p, targetDb: -1);
  return p;
}

Pcm voiceEffect(Pcm input, String kind) {
  final mono = toMono(input);
  switch (kind) {
    case 'chipmunk':
      return pitchShift(mono, 1.6);
    case 'giant':
      return pitchShift(mono, 0.68);
    case 'echo':
      return _delay(mono, 0.28, 0.45, 0.5);
    case 'cave':
      return reverb(mono, size: 1.8, wet: 0.55);
    case 'radio':
      return _radio(mono);
    default:
      return _robot(mono);
  }
}

Pcm _radio(Pcm mono) {
  final hp = Biquad.highpass(mono.rate.toDouble(), 400);
  final lp = Biquad.lowpass(mono.rate.toDouble(), 2800);
  final rnd = math.Random(3);
  final out = Float32List(mono.frames);
  for (var i = 0; i < out.length; i++) {
    final v = lp.process(hp.process(mono.samples[i])) * 2.5;
    out[i] = (v / (1 + v.abs())) * 0.9 + (rnd.nextDouble() - 0.5) * 0.02;
  }
  return Pcm(mono.rate, 1, out);
}

/// Robot: halka modülasyonu + kısa tarak.
Pcm _robot(Pcm mono) {
  final out = Float32List(mono.frames);
  final d = (0.012 * mono.rate).round();
  for (var i = 0; i < out.length; i++) {
    final m = math.sin(2 * math.pi * 55 * i / mono.rate);
    final v = mono.samples[i] * m;
    out[i] = v + (i >= d ? out[i - d] * 0.4 : 0.0);
  }
  final p = Pcm(mono.rate, 1, out);
  normalizePeak(p, targetDb: -2);
  return p;
}

// --------------------------------------------------------------------- gürültü azaltma

/// Spektral geçitleme: en sessiz karelerden gürültü profili çıkarılır ve
/// her frekansta bu profilin altında kalan enerji bastırılır. [strength] 0..1.
Pcm reduceNoise(Pcm input, {double strength = 0.7}) {
  final mono = toMono(input);
  const size = 1024, hop = 256;
  final n = mono.frames;
  if (n < size * 2) return mono.copy();
  final win = Float64List.fromList(List<double>.generate(size, (i) => 0.5 - 0.5 * math.cos(2 * math.pi * i / size)));
  final frames = (n - size) ~/ hop + 1;
  final mags = <Float64List>[];
  final energies = <double>[];
  for (var f = 0; f < frames; f++) {
    final re = Float64List(size), im = Float64List(size);
    for (var i = 0; i < size; i++) {
      re[i] = mono.samples[f * hop + i] * win[i];
    }
    fft(re, im);
    final m = Float64List(size ~/ 2 + 1);
    var e = 0.0;
    for (var k = 0; k < m.length; k++) {
      m[k] = math.sqrt(re[k] * re[k] + im[k] * im[k]);
      e += m[k];
    }
    mags.add(m);
    energies.add(e);
  }
  final order = List<int>.generate(frames, (i) => i)..sort((a, b) => energies[a].compareTo(energies[b]));
  final quiet = order.take(math.max<int>(1, frames ~/ 10)).toList();
  final profile = Float64List(size ~/ 2 + 1);
  for (final q in quiet) {
    for (var k = 0; k < profile.length; k++) {
      profile[k] += mags[q][k] / quiet.length;
    }
  }
  final over = 1.0 + 2.0 * strength;
  // En düşük kazanç: güç arttıkça gürültü daha çok bastırılır.
  final floor = 1 - strength * 0.9;
  final out = Float64List(n);
  final norm = Float64List(n);
  final prevGain = Float64List(size ~/ 2 + 1)..fillRange(0, size ~/ 2 + 1, 1);
  for (var f = 0; f < frames; f++) {
    final re = Float64List(size), im = Float64List(size);
    for (var i = 0; i < size; i++) {
      re[i] = mono.samples[f * hop + i] * win[i];
    }
    fft(re, im);
    for (var k = 0; k <= size ~/ 2; k++) {
      final m = mags[f][k];
      var g = m <= 1e-12 ? 0.0 : (1 - over * profile[k] / m);
      g = math.max(floor, g);
      g = 0.6 * g + 0.4 * prevGain[k];
      prevGain[k] = g;
      re[k] *= g;
      im[k] *= g;
      if (k > 0 && k < size ~/ 2) {
        re[size - k] *= g;
        im[size - k] *= g;
      }
    }
    ifft(re, im);
    for (var i = 0; i < size; i++) {
      out[f * hop + i] += re[i] * win[i];
      norm[f * hop + i] += win[i] * win[i];
    }
  }
  final res = Float32List(n);
  for (var i = 0; i < n; i++) {
    res[i] = norm[i] > 1e-6 ? out[i] / norm[i] : mono.samples[i] * 0;
  }
  return Pcm(mono.rate, 1, res);
}

// --------------------------------------------------------------------- dizici

/// [grid]: satır = enstrüman (kDrumIds sırası), sütun = adım (16'lık nota).
Pcm renderPattern(List<List<bool>> grid, double bpm, {int rate = 44100, int loops = 1, List<double>? levels}) {
  final steps = grid.isEmpty ? 16 : grid.first.length;
  final stepSec = 60 / bpm / 4;
  final loopFrames = (steps * stepSec * rate).round();
  final total = loopFrames * loops;
  final out = Float32List(total);
  for (var r = 0; r < grid.length && r < kDrumIds.length; r++) {
    final s = drum(kDrumIds[r], rate: rate);
    final lv = levels != null && r < levels.length ? levels[r] : 0.8;
    for (var l = 0; l < loops; l++) {
      for (var c = 0; c < steps; c++) {
        if (!grid[r][c]) continue;
        final at = l * loopFrames + (c * stepSec * rate).round();
        for (var i = 0; i < s.frames; i++) {
          // Döngü dışına taşan kuyruk başa sarılır (kesintisiz tekrar).
          out[(at + i) % total] += s.samples[i] * lv;
        }
      }
    }
  }
  final p = Pcm(rate, 1, out);
  if (peakOf(p) > 0.98) normalizePeak(p, targetDb: -1);
  return p;
}

// --------------------------------------------------------------------- SRT

String srtTime(Duration d) {
  String two(int v) => v.toString().padLeft(2, '0');
  final ms = d.inMilliseconds % 1000;
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)},${ms.toString().padLeft(3, '0')}';
}

String toSrt(List<(Duration, Duration, String)> cues) {
  final b = StringBuffer();
  var i = 1;
  for (final c in cues) {
    if (c.$3.trim().isEmpty) continue;
    b.writeln(i++);
    b.writeln('${srtTime(c.$1)} --> ${srtTime(c.$2)}');
    b.writeln(c.$3.trim());
    b.writeln();
  }
  return b.toString();
}

String toVtt(List<(Duration, Duration, String)> cues) {
  final b = StringBuffer('WEBVTT\n\n');
  for (final c in cues) {
    if (c.$3.trim().isEmpty) continue;
    b.writeln('${srtTime(c.$1).replaceAll(',', '.')} --> ${srtTime(c.$2).replaceAll(',', '.')}');
    b.writeln(c.$3.trim());
    b.writeln();
  }
  return b.toString();
}

String fmtClock(double sec) {
  final s = sec.isFinite ? sec.round() : 0;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
