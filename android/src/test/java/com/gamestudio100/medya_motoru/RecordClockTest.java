package com.gamestudio100.medya_motoru;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class RecordClockTest {
  @Test
  public void beforeStartAndBeforeBaseAreDropped() {
    RecordClock c = new RecordClock();
    assertEquals(-1, c.toOutputUs(5));
    c.start(1000);
    assertEquals(-1, c.toOutputUs(999));
    assertEquals(0, c.toOutputUs(1000));
    assertEquals(500, c.toOutputUs(1500));
  }

  @Test
  public void pauseFreezesAndOffsetsIdentically() {
    RecordClock c = new RecordClock();
    c.start(0);
    assertTrue(c.pause(1000));
    assertFalse(c.pause(1200));
    assertTrue(c.isPaused());
    assertEquals(-1, c.toOutputUs(1000));
    assertEquals(-1, c.toOutputUs(1500));
    assertEquals(1000, c.nowOutputUs(1800));
    assertTrue(c.resume(2000));
    assertFalse(c.resume(2100));
    assertEquals(1000, c.pausedTotalUs());
    assertEquals(1000, c.nowOutputUs(2000));
    assertEquals(1000, c.toOutputUs(2000));
    assertEquals(1500, c.toOutputUs(2500));
    assertEquals(1500, c.nowOutputUs(2500));
  }

  @Test
  public void frameCapturedBeforePauseKeepsItsTime() {
    RecordClock c = new RecordClock();
    c.start(0);
    c.pause(1000);
    c.resume(4000);
    c.pause(5000);
    c.resume(6000);
    // Duraklatmadan önce yakalanıp sonra çıkan kare: ofset uygulanmaz.
    assertEquals(900, c.toOutputUs(900));
    // İlk duraklatmanın içi atılır.
    assertEquals(-1, c.toOutputUs(3999));
    // İki duraklatma arası: yalnız ilk ofset.
    assertEquals(1500, c.toOutputUs(4500));
    assertEquals(-1, c.toOutputUs(5500));
    // İkisinden sonra: toplam ofset.
    assertEquals(2500, c.toOutputUs(6500));
    assertEquals(4000, c.pausedTotalUs());
    assertEquals(2500, c.nowOutputUs(6500));
  }

  @Test
  public void outputIsMonotonicAcrossPauses() {
    RecordClock c = new RecordClock();
    c.start(0);
    long prev = -1;
    for (long t = 0; t < 20_000; t += 10) {
      if (t == 3000) c.pause(t);
      if (t == 7000) c.resume(t);
      if (t == 12_000) c.pause(t);
      if (t == 12_500) c.resume(t);
      long o = c.toOutputUs(t);
      if (o < 0) continue;
      assertTrue(o >= prev);
      prev = o;
    }
    assertEquals(20_000 - 10 - 4500, prev);
  }
}
