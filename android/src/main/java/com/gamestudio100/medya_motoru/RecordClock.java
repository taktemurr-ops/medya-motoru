package com.gamestudio100.medya_motoru;

import java.util.ArrayList;
import java.util.List;

/**
 * Kaydın ortak zaman çizelgesi (saf Java, Android bağımlılığı yok; JVM'de test edilir).
 *
 * Ses ve görüntü aynı saati kullanır: yakalama anı (System.nanoTime()/1000,
 * mikrosaniye) çıktı zamanına {@link #toOutputUs(long)} ile çevrilir. Duraklatma
 * aralıkları tek tek tutulur; bir anın ofseti yalnız o andan ÖNCE biten
 * duraklatmaların toplamıdır. Böylece duraklatmadan önce yakalanıp sonra
 * kodlayıcıdan çıkan kare de doğru zamanı alır ve ses ile görüntü birebir aynı
 * ofsetle kayar.
 */
final class RecordClock {
  private long baseUs;
  private boolean started;
  /** Biten duraklatmalar: [başlangıç, bitiş) çiftleri, sıralı. */
  private final List<long[]> pauses = new ArrayList<>();
  private long pauseStartUs = -1;
  private long pausedTotalUs;

  synchronized void start(long nowUs) {
    baseUs = nowUs;
    started = true;
    pauses.clear();
    pauseStartUs = -1;
    pausedTotalUs = 0;
  }

  synchronized long baseUs() {
    return baseUs;
  }

  synchronized boolean isPaused() {
    return pauseStartUs >= 0;
  }

  /** Duraklatır; zaten duraklatılmışsa false. */
  synchronized boolean pause(long nowUs) {
    if (!started || pauseStartUs >= 0) return false;
    pauseStartUs = Math.max(nowUs, lastBoundary());
    return true;
  }

  /** Sürdürür; duraklatılmamışsa false. */
  synchronized boolean resume(long nowUs) {
    if (pauseStartUs < 0) return false;
    long end = Math.max(nowUs, pauseStartUs);
    pauses.add(new long[] {pauseStartUs, end});
    pausedTotalUs += end - pauseStartUs;
    pauseStartUs = -1;
    return true;
  }

  synchronized long pausedTotalUs() {
    return pausedTotalUs;
  }

  private long lastBoundary() {
    return pauses.isEmpty() ? baseUs : pauses.get(pauses.size() - 1)[1];
  }

  /**
   * Yakalama anını çıktı zamanına çevirir. Kayıt başlamadan önceki ya da bir
   * duraklatmanın içine düşen anlar için -1 (atılmalı).
   */
  synchronized long toOutputUs(long captureUs) {
    if (!started || captureUs < baseUs) return -1;
    if (pauseStartUs >= 0 && captureUs >= pauseStartUs) return -1;
    long off = 0;
    for (long[] p : pauses) {
      if (captureUs < p[0]) break;
      if (captureUs < p[1]) return -1;
      off += p[1] - p[0];
    }
    return captureUs - baseUs - off;
  }

  /** Şu anki çıktı konumu; duraklatılmışken duraklatmanın başladığı yerde donar. */
  synchronized long nowOutputUs(long nowUs) {
    if (!started) return 0;
    if (pauseStartUs >= 0) return Math.max(0, pauseStartUs - baseUs - pausedTotalUs);
    return Math.max(0, nowUs - baseUs - pausedTotalUs);
  }
}
