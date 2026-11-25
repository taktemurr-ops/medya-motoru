import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:medya_motoru/medya_motoru.dart';
import 'package:studio_core/app/services/ads.dart';
import 'package:studio_core/app/services/purchases.dart';
import 'package:studio_core/apps/apps.dart';
import 'package:studio_core/core/save_store.dart';

Pcm sine(double freq, double sec, {int rate = 8000, double amp = 0.5}) => Pcm(
      rate,
      1,
      Float32List.fromList(List<double>.generate((sec * rate).round(), (i) => amp * math.sin(2 * math.pi * freq * i / rate))),
    );

Rgba gradient(int w, int h, {bool invert = false}) {
  final r = Rgba(w, h, Uint8List(w * h * 4));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      final v = ((x + y) * 255 ~/ (w + h - 2)).clamp(0, 255);
      final g = x * 255 ~/ math.max<int>(1, w - 1);
      final b = y * 255 ~/ math.max<int>(1, h - 1);
      r.data[i] = invert ? 255 - v : v;
      r.data[i + 1] = invert ? 255 - g : g;
      r.data[i + 2] = invert ? 255 - b : b;
      r.data[i + 3] = 255;
    }
  }
  return r;
}

void main() {
  test('42 araç, 33 dilde ad ve açıklama, geçerli kategori ve öne çıkanlar', () {
    expect(medyaTools.length, 42);
    expect(medyaTools.map((t) => t.id).toSet().length, 42);
    for (final t in medyaTools) {
      expect(t.title.length, 33, reason: t.id);
      expect(t.tagline.length, 33, reason: t.id);
      expect(t.title.every((s) => s.trim().isNotEmpty), isTrue, reason: t.id);
      expect(t.id.startsWith('uyg-'), isTrue);
      expect(medyaCategories.any((c) => c.id == t.category), isTrue, reason: t.id);
    }
    for (final f in medyaFeatured) {
      expect(medyaTools.any((t) => t.id == f), isTrue, reason: f);
    }
    expect(medyaHubTitle.length, 33);
    expect(medyaHubTagline.length, 33);
    expect(medyaCategories.length, 6);
  });

  group('ses', () {
    test('WAV yazılıp geri okunur', () {
      final p = sine(440, 0.25);
      final back = decodeWav(encodeWav(p))!;
      expect(back.rate, 8000);
      expect(back.channels, 1);
      expect(back.frames, p.frames);
      for (var i = 0; i < p.frames; i += 97) {
        expect(back.samples[i], closeTo(p.samples[i], 1 / 16000));
      }
      expect(decodeWav(Uint8List.fromList(List<int>.filled(60, 0))), isNull);
    });

    test('kesme, yumuşak geçiş, seviye, ters çevirme', () {
      final p = sine(200, 2);
      final c = trimPcm(p, 0.5, 1.5);
      expect(c.frames, 8000);
      fadeIn(c, 0.1);
      expect(c.samples.first.abs(), lessThan(1e-6));
      normalizePeak(c, targetDb: -6);
      expect(peakOf(c), closeTo(dbToGain(-6), 1e-3));
      final r = reversePcm(c);
      expect(r.samples.first, c.samples.last);
      final b = sine(200, 0.5, amp: 0.9)..samples[10] = 3.0;
      softLimit(b);
      expect(peakOf(b), lessThanOrEqualTo(0.98 + 1e-9));
    });

    test('örnekleme hızı dönüşümü ve karışım', () {
      final p = sine(100, 1, rate: 8000);
      expect(resample(p, 16000).frames, 16000);
      expect(resample(p, 4000).frames, 4000);
      final m = mix([sine(100, 1), sine(150, 0.5)], [0.5, 0.5]);
      expect(m.frames, 8000);
    });

    test('FFT tepe frekansı doğru kutuda', () {
      const n = 256;
      final re = Float64List(n), im = Float64List(n);
      for (var i = 0; i < n; i++) {
        re[i] = math.sin(2 * math.pi * 16 * i / n);
      }
      fft(re, im);
      var best = 0;
      for (var k = 1; k < n ~/ 2; k++) {
        if (re[k] * re[k] + im[k] * im[k] > re[best] * re[best] + im[best] * im[best]) best = k;
      }
      expect(best, 16);
      ifft(re, im);
      expect(re[5], closeTo(math.sin(2 * math.pi * 16 * 5 / n), 1e-9));
    });

    test('gürültü azaltma sessiz bölümdeki gürültüyü düşürür', () {
      const rate = 16000;
      final rnd = math.Random(1);
      final s = Float32List(rate * 2);
      for (var i = 0; i < s.length; i++) {
        s[i] = (rnd.nextDouble() * 2 - 1) * 0.05 + (i > rate ? 0.5 * math.sin(2 * math.pi * 440 * i / rate) : 0);
      }
      final p = Pcm(rate, 1, s);
      final out = reduceNoise(p, strength: 0.9);
      expect(out.frames, p.frames);
      final before = rmsOf(trimPcm(p, 0.1, 0.9));
      final after = rmsOf(trimPcm(out, 0.1, 0.9));
      expect(after, lessThan(before * 0.6));
      expect(rmsOf(trimPcm(out, 1.2, 1.8)), greaterThan(0.2));
    });

    test('davul, piyano, sentez ve efektler', () {
      expect(kDrumIds.length, 8);
      for (final d in kDrumIds) {
        final p = drum(d, rate: 8000);
        expect(p.frames, greaterThan(0), reason: d);
        expect(peakOf(p), greaterThan(0.1), reason: d);
      }
      expect(midiFreq(69), 440);
      expect(midiFreq(81), closeTo(880, 1e-9));
      expect(pianoNote(60, rate: 8000, seconds: 0.5).frames, 4000);
      expect(synthNote(60, const SynthPatch(), rate: 8000, hold: 0.25).frames, (0.55 * 8000).round());
      final v = sine(220, 1);
      for (final fx in kVoiceIds) {
        expect(voiceEffect(v, fx).frames, greaterThanOrEqualTo(v.frames), reason: fx);
      }
      expect(pitchShift(v, 1.5).frames, v.frames);
    });

    test('ortam sesleri döngüye hazır ve sessiz değil', () {
      for (final k in kNoiseIds) {
        final p = ambient(k, seconds: 2, rate: 8000);
        expect(p.frames, greaterThan(8000), reason: k);
        expect(rmsOf(p), greaterThan(0.01), reason: k);
      }
    });

    test('ritim dizicisi doğru uzunlukta döngü üretir', () {
      final grid = List<List<bool>>.generate(8, (r) => List<bool>.generate(16, (c) => r == 0 && c % 4 == 0));
      final p = renderPattern(grid, 120, rate: 8000, loops: 2);
      expect(p.frames, (16 * (60 / 120 / 4) * 8000).round() * 2);
      expect(peakOf(p), greaterThan(0.1));
    });

    test('SRT ve VTT biçimi', () {
      final cues = [
        (const Duration(seconds: 1, milliseconds: 5), const Duration(seconds: 3, milliseconds: 250), ' Merhaba '),
        (const Duration(hours: 1, minutes: 2, seconds: 3), const Duration(hours: 1, minutes: 2, seconds: 4), 'İkinci'),
      ];
      expect(toSrt(cues), '1\n00:00:01,005 --> 00:00:03,250\nMerhaba\n\n2\n01:02:03,000 --> 01:02:04,000\nİkinci\n\n');
      expect(toVtt(cues).startsWith('WEBVTT\n\n00:00:01.005 --> 00:00:03.250\nMerhaba'), isTrue);
      expect(fmtClock(125), '2:05');
      expect(whisperLang('fil'), 'tl');
      expect(whisperLang('nb'), 'no');
      expect(whisperLang('tr'), 'tr');
      expect(kAppLangs.length, 33);
    });
  });

  group('görüntü', () {
    test('renk matrisleri', () {
      final g = gradient(8, 8);
      final c = g.copy();
      applyMatrix(c, identityMatrix());
      expect(c.data, g.data);
      final m = editMatrix();
      for (var i = 0; i < 20; i++) {
        expect(m[i], closeTo(identityMatrix()[i], 1e-9), reason: '$i');
      }
      final gray = g.copy();
      applyMatrix(gray, saturationMatrix(0));
      for (var i = 0; i < gray.data.length; i += 4) {
        expect((gray.data[i] - gray.data[i + 1]).abs(), lessThanOrEqualTo(1));
        expect((gray.data[i + 1] - gray.data[i + 2]).abs(), lessThanOrEqualTo(1));
      }
      for (final f in kFilterIds) {
        expect(filterMatrix(f).length, 20, reason: f);
      }
      final bright = g.copy();
      applyMatrix(bright, brightnessMatrix(0.5));
      expect(bright.data[0], greaterThan(g.data[0]));
    });

    test('kırpma, sığdırma, pikselleştirme ve bulanıklık', () {
      expect(centeredCrop(400, 200, 1), (x: 100, y: 0, w: 200, h: 200));
      expect(centeredCrop(200, 400, 16 / 9), (x: 0, y: 143, w: 200, h: 113));
      expect(fitWithin(4000, 3000, 2000), (w: 2000, h: 1500));
      expect(fitWithin(100, 50, 2000), (w: 100, h: 50));
      final g = gradient(32, 32);
      final c = cropRgba(g, 4, 4, 8, 8);
      expect(c.width, 8);
      expect(c.data.sublist(0, 4), g.data.sublist(g.index(4, 4), g.index(4, 4) + 4));
      final p = g.copy();
      pixelate(p, 0, 0, 8, 8, 4);
      expect(p.data[p.index(0, 0)], p.data[p.index(3, 3)]);
      final b = g.copy();
      blurRegion(b, 0, 0, 32, 32);
      expect(b.width, 32);
      final r = resizeBilinear(g, 16, 8);
      expect(r.data.length, 16 * 8 * 4);
      sharpen(g.copy(), 0.5);
      vignette(g.copy(), 0.5);
    });

    test('dHash ile benzer fotoğraflar gruplanır', () {
      final a = gradient(64, 48);
      final b = resizeBilinear(a, 80, 60);
      final c = gradient(64, 48, invert: true);
      final ha = dHash(a), hb = dHash(b), hc = dHash(c);
      expect(hamming(ha, ha), 0);
      expect(hamming(ha, hb), lessThanOrEqualTo(6));
      expect(hamming(ha, hc), greaterThan(10));
      final groups = groupSimilar([ha, hc, hb], 6);
      expect(groups.length, 1);
      expect(groups.first, [0, 2]);
    });

    test('kolaj hücreleri birim kare içinde', () {
      for (var n = 1; n <= 9; n++) {
        for (var v = 0; v < 3; v++) {
          final cells = collageCells(n, v);
          expect(cells.length, n, reason: '$n/$v');
          for (final c in cells) {
            expect(c[0] >= 0 && c[1] >= 0 && c[0] + c[2] <= 1.0001 && c[1] + c[3] <= 1.0001, isTrue);
          }
        }
      }
    });

    test('Lab dönüşümü gidiş-dönüş', () {
      for (final c in [(0, 0, 0), (255, 255, 255), (200, 30, 60), (12, 180, 90), (40, 40, 220)]) {
        final lab = rgbToLab(c.$1, c.$2, c.$3);
        final back = labToRgb(lab.$1, lab.$2, lab.$3);
        expect((back.$1 - c.$1).abs(), lessThanOrEqualTo(2));
        expect((back.$2 - c.$2).abs(), lessThanOrEqualTo(2));
        expect((back.$3 - c.$3).abs(), lessThanOrEqualTo(2));
      }
      final g = gradient(20, 20);
      expect(lightnessInput(g).length, kColorSize * kColorSize);
      final gray = Float32List(2 * kColorSize * kColorSize);
      final out = combineLab(g, gray);
      expect(out.width, 20);
    });

    test('U²-Netp girdi/çıktı ve maske', () {
      final g = gradient(50, 40);
      expect(u2Input(g).length, 3 * kU2Size * kU2Size);
      final raw = Float32List.fromList(List<double>.generate(kU2Size * kU2Size, (i) => i % kU2Size < kU2Size / 2 ? 0.1 : 0.9));
      final mask = u2Mask(raw);
      expect(mask.first, 0);
      expect(mask[kU2Size - 1], 255);
      final c = g.copy();
      applyMask(c, mask, kU2Size, kU2Size);
      expect(c.data[3], lessThan(30));
      expect(c.data[c.index(49, 0) + 3], greaterThan(220));
    });

    test('karolama: karolar birleşince büyütülmüş görüntü aynen oluşur', () {
      final src = gradient(70, 45);
      const scale = 4, tile = 32, overlap = 4;
      final dst = Rgba(src.width * scale, src.height * scale, Uint8List(src.width * scale * src.height * scale * 4));
      for (final t in tiles(src.width, src.height, tile, overlap)) {
        final up = upscaleNearest(cropRgba(src, t.x, t.y, t.w, t.h), scale);
        pasteTile(dst, up, t, scale, overlap, tile - 2 * overlap);
      }
      expect(dst.data, upscaleNearest(src, scale).data);
      final planar = rgbPlanar(src);
      expect(fromPlanar(planar, src.width, src.height).data[src.index(10, 10)], src.data[src.index(10, 10)]);
    });

    test('doldurma, plaka tanıma, çift boyutlar, şekiller', () {
      final px = List<int>.filled(16, 0);
      px[5] = 1;
      floodFill(px, 4, 0, 0, 7);
      expect(px.where((v) => v == 7).length, 15);
      expect(looksLikePlate('34 ABC 123'), isTrue);
      expect(looksLikePlate('HELLO'), isFalse);
      expect(looksLikePlate('12345'), isFalse);
      expect(even(1081), 1080);
      expect(even(3000), 1920);
      expect(evenFit(4000, 3000, 1280), (w: 1280, h: 960));
      for (final s in ['circle', 'square', 'hexagon', 'star']) {
        expect(shapePath(s, const Offset(10, 10), 5).getBounds().width, greaterThan(5));
      }
      expect(paletteFromSeed(3).length, 3);
      expect(readPhotoMeta(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('GIF kodlama iki kareden geçerli dosya üretir', () {
      final a = img.encodePng(img.Image(width: 30, height: 20)..clear(img.ColorRgb8(255, 0, 0)));
      final b = img.encodePng(img.Image(width: 20, height: 30)..clear(img.ColorRgb8(0, 0, 255)));
      final g = gifJob((frames: [a, b], maxSide: 24, delayCs: 10))!;
      expect(String.fromCharCodes(g.sublist(0, 6)), 'GIF89a');
      final decoded = img.decodeGif(g)!;
      expect(decoded.width, 24);
      expect(decoded.numFrames, 2);
    });
  });

  // Eklenti gerektirmeyen ekranlar (ses çalar/kamera/mikrofon açmayanlar) açılır.
  for (final id in [
    'uyg-fotograf-duzenleyici', 'uyg-kolaj', 'uyg-kirp-ve-boyutlandir', 'uyg-fotograf-sikistirma',
    'uyg-filigran-ekleme', 'uyg-meme-yapici', 'uyg-gorselden-pdf', 'uyg-duvar-kagidi-uretici',
    'uyg-fotograf-bilgisi-silici', 'uyg-kopya-fotograf-bulucu', 'uyg-ekran-goruntusu-duzenleyici',
    'uyg-piksel-sanati-editoru', 'uyg-dijital-resim-ve-boyama', 'uyg-logo-tasarimi',
    'uyg-davetiye-ve-kart-tasarimi', 'uyg-afis-ve-sosyal-medya-tasarimi', 'uyg-gif-yapici',
    'uyg-video-kirp-ve-birlestir', 'uyg-video-sikistirma', 'uyg-video-hiz', 'uyg-videodan-ses-cikarma',
    'uyg-slayt-gosterisi-video', 'uyg-arka-plan-silme', 'uyg-fotograf-iyilestirme',
    'uyg-yuz-ve-plaka-bulaniklastirma', 'uyg-ses-formati-donusturucu',
  ]) {
    testWidgets('araç ekranı açılır: $id', (tester) async {
      final s = AppServices(hubId: 'm', backend: MemoryBackend(), ads: NoAdsService(), purchases: NoPurchaseService());
      final tool = medyaTool(id);
      final ctx = ToolContext(toolId: id, lang: 'tr', store: s.storeFor(id), services: s);
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: AppLook(style: medyaHubStyle, child: Scaffold(body: Builder(builder: (c) => tool.builder(c, ctx)))),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  }
}
