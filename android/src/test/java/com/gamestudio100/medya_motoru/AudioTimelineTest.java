package com.gamestudio100.medya_motoru;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class AudioTimelineTest {
  private static final int RATE = 44100;
  private static final int CHUNK = 1024;

  /** Saat: n parça tam dolmuş olsun diye yukarı yuvarlanır. */
  private static long chunkUs(int n) {
    return ((long) n * CHUNK * 1_000_000L + RATE - 1) / RATE;
  }

  /** Beklenen sunum zamanı (aşağı yuvarlanır, AudioTimeline ile aynı). */
  private static long ptsUs(int n) {
    return (long) n * CHUNK * 1_000_000L / RATE;
  }

  @Test
  public void noCaptureData_producesSilenceOnWallClock() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, false);
    short[] out = new short[CHUNK * 2];
    // Saat bir parçayı geçmedi: bekle.
    assertEquals(0, tl.next(chunkUs(1) - 1000, out));
    // Bir parça geçti ama süre payı dolmadı: hâlâ bekle (veri gelebilir).
    assertEquals(0, tl.next(chunkUs(1) + 1000, out));
    // İki parça (bir parça + pay) geçti, veri yok: sessizlik.
    out[0] = 99;
    assertEquals(CHUNK, tl.next(chunkUs(2) + 1, out));
    assertEquals(0, tl.lastPtsUs());
    for (short v : out) assertEquals(0, v);
    assertEquals(CHUNK, tl.silentFrames());
    // Uzun süre veri yok: parçalar ardışık, boşluksuz zaman damgalarıyla.
    long prev = tl.lastPtsUs();
    int made = 0;
    while (tl.next(chunkUs(20), out) > 0) {
      long pts = tl.lastPtsUs();
      assertEquals(ptsUs(made + 1), pts);
      assertTrue(pts > prev);
      prev = pts;
      made++;
    }
    // 20 parçalık saatte en fazla 19 parça (son parça pay içinde bekler).
    assertEquals(18, made);
    assertEquals(ptsUs(19), tl.nextPtsUs());
  }

  @Test
  public void realData_emittedWithoutWaitingForGrace() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, false);
    short[] in = new short[CHUNK * 2];
    for (int i = 0; i < in.length; i++) in[i] = (short) (i % 100);
    tl.pushApp(in, in.length);
    short[] out = new short[CHUNK * 2];
    assertEquals(CHUNK, tl.next(chunkUs(1), out));
    assertArrayEquals(in, out);
    assertEquals(0, tl.silentFrames());
  }

  @Test
  public void audioNeverRunsAheadOfClock() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, false);
    short[] in = new short[CHUNK * 2 * 3];
    tl.pushApp(in, in.length);
    short[] out = new short[CHUNK * 2];
    assertEquals(0, tl.next(0, out));
    assertEquals(CHUNK, tl.next(chunkUs(1), out));
    assertEquals(0, tl.next(chunkUs(1), out));
    assertEquals(2 * CHUNK, tl.queuedApp());
  }

  @Test
  public void partialData_paddedWithSilence() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, false);
    short[] in = new short[200];
    java.util.Arrays.fill(in, (short) 7);
    tl.pushApp(in, in.length);
    short[] out = new short[CHUNK * 2];
    assertEquals(0, tl.next(chunkUs(1), out));
    assertEquals(CHUNK, tl.next(chunkUs(2), out));
    assertEquals(7, out[199]);
    assertEquals(0, out[200]);
    assertEquals(CHUNK - 100, tl.silentFrames());
  }

  @Test
  public void micMixedIntoBothChannels_andMissingAppIsSilent() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, true);
    short[] mic = new short[CHUNK];
    java.util.Arrays.fill(mic, (short) 1000);
    tl.pushMic(mic, mic.length);
    short[] out = new short[CHUNK * 2];
    // Mikrofon hazır ama uygulama sesi yok: pay dolana dek bekle.
    assertEquals(0, tl.next(chunkUs(1), out));
    assertEquals(CHUNK, tl.next(chunkUs(2), out));
    assertEquals(1000, out[0]);
    assertEquals(1000, out[1]);
    assertEquals(1000, out[CHUNK * 2 - 1]);
  }

  @Test
  public void micOnly_noAppSource() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, false, true);
    short[] mic = new short[CHUNK];
    java.util.Arrays.fill(mic, (short) -5);
    tl.pushMic(mic, mic.length);
    short[] out = new short[CHUNK * 2];
    assertEquals(CHUNK, tl.next(chunkUs(1), out));
    assertEquals(-5, out[0]);
    assertEquals(-5, out[1]);
  }

  @Test
  public void mixClips() {
    short[] st = {30000, -30000};
    short[] mo = {10000};
    short[] out = new short[2];
    AudioTimeline.mix(st, mo, out, 1);
    assertEquals(32767, out[0]);
    assertEquals(-20000, out[1]);
    AudioTimeline.mix(null, new short[] {-32768}, out, 1);
    assertEquals(-32768, out[0]);
    AudioTimeline.mix(new short[] {5, 6}, null, out, 1);
    assertEquals(5, out[0]);
    assertEquals(6, out[1]);
  }

  @Test
  public void backlogIsBounded() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, false);
    short[] in = new short[CHUNK * 2 * 10];
    tl.pushApp(in, in.length);
    short[] out = new short[CHUNK * 2];
    assertEquals(CHUNK, tl.next(chunkUs(1), out));
    assertTrue(tl.queuedApp() <= tl.maxQueueFrames);
  }

  @Test
  public void discardInputClearsQueues() {
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, true);
    tl.pushApp(new short[100], 100);
    tl.pushMic(new short[100], 100);
    tl.discardInput();
    assertEquals(0, tl.queuedApp());
    assertEquals(0, tl.queuedMic());
  }

  @Test
  public void fifoKeepsFrameAlignmentAndOrder() {
    AudioTimeline.PcmFifo f = new AudioTimeline.PcmFifo(2, 4);
    f.push(new short[] {1, 2, 3, 4, 5}, 5); // tek örnek kesilir
    assertEquals(2, f.frames());
    f.push(new short[] {5, 6, 7, 8, 9, 10}, 6); // taşma: en eski kare atılır
    assertEquals(4, f.frames());
    short[] d = new short[8];
    assertEquals(4, f.pop(d, 4));
    assertArrayEquals(new short[] {3, 4, 5, 6, 7, 8, 9, 10}, d);
    assertFalse(f.frames() > 0);
  }

  @Test
  public void pauseResume_audioAndVideoShareOffset() {
    RecordClock c = new RecordClock();
    c.start(1_000_000);
    AudioTimeline tl = new AudioTimeline(RATE, CHUNK, true, false);
    short[] out = new short[CHUNK * 2];
    // 1 s kayıt, sessizlik.
    long now = 2_000_000;
    int before = 0;
    while (tl.next(c.nowOutputUs(now), out) > 0) before++;
    long lastBefore = tl.lastPtsUs();
    c.pause(now);
    // Duraklatma süresince saat donar: yeni parça yok.
    assertEquals(0, tl.next(c.nowOutputUs(now + 5_000_000), out));
    c.resume(now + 5_000_000);
    long after = now + 5_000_000 + 500_000;
    int made = 0;
    while (tl.next(c.nowOutputUs(after), out) > 0) {
      made++;
      // Ses zaman damgası duraklatma süresini içermez.
      assertTrue(tl.lastPtsUs() < 1_500_000);
    }
    assertTrue(made > 0);
    assertTrue(tl.lastPtsUs() > lastBefore);
    // Aynı anda yakalanmış görüntü karesi aynı çıktı saatine düşer.
    assertEquals(1_500_000, c.toOutputUs(after));
    assertEquals(1_500_000, c.nowOutputUs(after));
    assertTrue(before > 0);
  }
}
