package com.gamestudio100.medya_motoru;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.media.audiofx.AudioEffect;
import android.media.audiofx.Equalizer;
import android.os.Build;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * Sistem geneli eşitleyici (Android'in izin verdiği ölçüde).
 *
 * <p>Pek çok müzik/video oynatıcısı çalarken ses oturumunu {@link
 * AudioEffect#ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION} yayınıyla duyurur; eşitleyici uygulamaları
 * bu oturuma {@link Equalizer} ekleyebilir. Bu sınıf yayını yalnız uygulama süreci yaşarken
 * (dinamik alıcıyla) dinler ve oturuma, Dart'tan gelen 31 noktalık eğriyi cihazın kendi bantlarına
 * ara değerleyerek uygular. Oturumunu duyurmayan oynatıcılar ve ses efektlerini engelleyen cihazlar
 * etkilenmez (arayüzde açıkça yazılır). Genel çıkış karışımına (oturum 0) eşitleyici eklenmez:
 * Android bunu kullanımdan kaldırmıştır.
 */
final class SystemEq {
  private SystemEq() {}

  private static final Map<Integer, Equalizer> effects = new HashMap<>();
  private static double[] curve = new double[0];
  private static BroadcastReceiver receiver;

  static synchronized boolean set(Context context, boolean on, List<?> points) {
    if (!on) {
      stop(context);
      return true;
    }
    final double[] c = new double[points == null ? 0 : points.size()];
    for (int i = 0; i < c.length; i++) {
      final Object v = points.get(i);
      c[i] = v instanceof Number ? ((Number) v).doubleValue() : 0;
    }
    curve = c;
    for (Equalizer e : effects.values()) apply(e);
    if (receiver == null) {
      receiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context ctx, Intent intent) {
          final int session = intent.getIntExtra(AudioEffect.EXTRA_AUDIO_SESSION, AudioEffect.ERROR_BAD_VALUE);
          if (session <= 0) return;
          if (AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION.equals(intent.getAction())) {
            open(session);
          } else {
            close(session);
          }
        }
      };
      final IntentFilter f = new IntentFilter();
      f.addAction(AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION);
      f.addAction(AudioEffect.ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION);
      if (Build.VERSION.SDK_INT >= 33) {
        context.registerReceiver(receiver, f, Context.RECEIVER_EXPORTED);
      } else {
        context.registerReceiver(receiver, f);
      }
    }
    return true;
  }

  static synchronized int sessions() {
    return effects.size();
  }

  static synchronized void stop(Context context) {
    if (receiver != null) {
      try {
        context.unregisterReceiver(receiver);
      } catch (IllegalArgumentException ignored) {
        // zaten kaldırılmış
      }
      receiver = null;
    }
    for (Equalizer e : effects.values()) {
      try {
        e.release();
      } catch (RuntimeException ignored) {
        // oturum kapanmış olabilir
      }
    }
    effects.clear();
  }

  private static synchronized void open(int session) {
    if (effects.containsKey(session)) return;
    try {
      final Equalizer e = new Equalizer(1, session);
      apply(e);
      effects.put(session, e);
    } catch (RuntimeException ignored) {
      // Cihaz ya da oynatıcı ses efektine izin vermiyor.
    }
  }

  private static synchronized void close(int session) {
    final Equalizer e = effects.remove(session);
    if (e != null) {
      try {
        e.release();
      } catch (RuntimeException ignored) {
        // yok say
      }
    }
  }

  /** 20 Hz–20 kHz log aralıklı eğriden [hz] için doğrusal ara değer (dB). */
  private static double at(double hz) {
    final double[] c = curve;
    if (c.length == 0) return 0;
    if (c.length == 1) return c[0];
    final double x = Math.log10(Math.max(20, Math.min(20000, hz)) / 20.0) / 3.0 * (c.length - 1);
    final int i = (int) Math.floor(x);
    if (i >= c.length - 1) return c[c.length - 1];
    final double t = x - i;
    return c[i] * (1 - t) + c[i + 1] * t;
  }

  private static void apply(Equalizer e) {
    try {
      final short n = e.getNumberOfBands();
      final short[] range = e.getBandLevelRange();
      for (short b = 0; b < n; b++) {
        final double hz = e.getCenterFreq(b) / 1000.0;
        int mb = (int) Math.round(at(hz) * 100);
        mb = Math.max(range[0], Math.min(range[1], mb));
        e.setBandLevel(b, (short) mb);
      }
      e.setEnabled(true);
    } catch (RuntimeException ignored) {
      // oturum kapanmış olabilir
    }
  }
}
