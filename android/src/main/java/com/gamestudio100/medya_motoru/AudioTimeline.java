package com.gamestudio100.medya_motoru;

/**
 * Duvar saatine bağlı ses zaman çizelgesi (saf Java; JVM'de test edilir).
 *
 * Kaynaklar (uygulama sesi stereo, mikrofon mono) engellemeden okunup
 * kuyruklara atılır; çıktı her zaman {@link #chunk} karelik parçalar halinde,
 * çıktı saati ilerledikçe üretilir. Sunum zamanı yalnızca üretilen kare
 * sayısından hesaplanır (kare*1e6/örnekleme hızı), bu yüzden ses hiçbir
 * zaman görüntüden kopmaz:
 *  - Saat bir parça kadar ilerlemediyse beklenir (ses öne geçmez).
 *  - Tüm kaynaklarda tam parça varsa gerçek veri yazılır.
 *  - Bir kaynak saatin bir parça + {@link #graceFrames} gerisinde kaldıysa
 *    (ör. hiçbir şey çalmıyor ve AudioPlaybackCapture veri vermiyor) eksik
 *    kısım sessizlikle doldurulur; kodlayıcı ve muxer hiç beklemez.
 *  - Gecikip birikmiş veri {@link #maxQueueFrames} üstüne çıkarsa en eskisi
 *    atılır (gecikme sınırlı kalır).
 * Duraklatmada {@link #discardInput()} ile kuyruklar boşaltılır; çıktı saati
 * {@link RecordClock} ile donar, ofset görüntüyle aynıdır.
 */
final class AudioTimeline {
  final int rate;
  final int chunk;
  final int graceFrames;
  final int maxQueueFrames;

  private final PcmFifo app; // stereo, null olabilir
  private final PcmFifo mic; // mono, null olabilir
  private final short[] appTmp;
  private final short[] micTmp;
  private long emittedFrames;
  private long silentFrames;
  private long lastPtsUs = -1;

  AudioTimeline(int rate, int chunk, boolean hasApp, boolean hasMic) {
    this(rate, chunk, chunk, chunk * 4, hasApp, hasMic);
  }

  AudioTimeline(int rate, int chunk, int graceFrames, int maxQueueFrames, boolean hasApp, boolean hasMic) {
    this.rate = rate;
    this.chunk = chunk;
    this.graceFrames = graceFrames;
    this.maxQueueFrames = Math.max(chunk, maxQueueFrames);
    int cap = this.maxQueueFrames + chunk * 4;
    app = hasApp ? new PcmFifo(2, cap) : null;
    mic = hasMic ? new PcmFifo(1, cap) : null;
    appTmp = new short[chunk * 2];
    micTmp = new short[chunk];
  }

  /** Uygulama sesi (stereo, iç içe) örnekleri. */
  void pushApp(short[] buf, int samples) {
    if (app != null && samples > 0) app.push(buf, samples);
  }

  /** Mikrofon (mono) örnekleri. */
  void pushMic(short[] buf, int samples) {
    if (mic != null && samples > 0) mic.push(buf, samples);
  }

  /** Duraklatmada gelen veriyi atar. */
  void discardInput() {
    if (app != null) app.clear();
    if (mic != null) mic.clear();
  }

  int queuedApp() {
    return app == null ? 0 : app.frames();
  }

  int queuedMic() {
    return mic == null ? 0 : mic.frames();
  }

  long emittedFrames() {
    return emittedFrames;
  }

  long silentFrames() {
    return silentFrames;
  }

  /** Son üretilen parçanın sunum zamanı (µs); yoksa -1. */
  long lastPtsUs() {
    return lastPtsUs;
  }

  /** Bir sonraki parçanın (ya da EOS'un) sunum zamanı. */
  long nextPtsUs() {
    return framesToUs(emittedFrames);
  }

  long framesToUs(long frames) {
    return frames * 1_000_000L / rate;
  }

  long usToFrames(long us) {
    return us * rate / 1_000_000L;
  }

  /**
   * Çıktı saati {@code outputUs} iken bir parça üretilecekse {@code outStereo}
   * (en az chunk*2) doldurulur ve {@link #chunk} döner; beklenecekse 0.
   * Sunum zamanı {@link #lastPtsUs()} ile alınır.
   */
  int next(long outputUs, short[] outStereo) {
    long lag = usToFrames(outputUs) - emittedFrames;
    if (lag < chunk) return 0;
    boolean full = (app == null || app.frames() >= chunk) && (mic == null || mic.frames() >= chunk);
    if (!full && lag < (long) chunk + graceFrames) return 0;
    int gotApp = app == null ? 0 : app.pop(appTmp, chunk);
    int gotMic = mic == null ? 0 : mic.pop(micTmp, chunk);
    for (int i = gotApp * 2; i < chunk * 2; i++) appTmp[i] = 0;
    for (int i = gotMic; i < chunk; i++) micTmp[i] = 0;
    int real = Math.max(gotApp, gotMic);
    silentFrames += chunk - real;
    mix(app == null ? null : appTmp, mic == null ? null : micTmp, outStereo, chunk);
    if (app != null && app.frames() > maxQueueFrames) app.drop(app.frames() - maxQueueFrames);
    if (mic != null && mic.frames() > maxQueueFrames) mic.drop(mic.frames() - maxQueueFrames);
    lastPtsUs = framesToUs(emittedFrames);
    emittedFrames += chunk;
    return chunk;
  }

  /** 16 bit PCM: stereo uygulama sesi + mono mikrofon, taşmada kırpılır. */
  static void mix(short[] stereo, short[] mono, short[] outBuf, int frames) {
    for (int i = 0; i < frames; i++) {
      int m = mono == null ? 0 : mono[i];
      for (int c = 0; c < 2; c++) {
        int j = i * 2 + c;
        int v = (stereo == null ? 0 : stereo[j]) + m;
        outBuf[j] = (short) Math.max(-32768, Math.min(32767, v));
      }
    }
  }

  /** Küçük halka tampon (kare = kanal sayısı kadar örnek). Taşarsa en eskiyi atar. */
  static final class PcmFifo {
    private final int ch;
    private final short[] buf;
    private int head, size; // örnek cinsinden

    PcmFifo(int channels, int capacityFrames) {
      ch = channels;
      buf = new short[channels * capacityFrames];
    }

    int frames() {
      return size / ch;
    }

    void clear() {
      head = 0;
      size = 0;
    }

    void push(short[] src, int samples) {
      samples -= samples % ch;
      int off = 0;
      if (samples > buf.length) {
        off = samples - buf.length;
        samples = buf.length;
      }
      int over = size + samples - buf.length;
      if (over > 0) dropSamples(over);
      for (int i = 0; i < samples; i++) {
        buf[(head + size + i) % buf.length] = src[off + i];
      }
      size += samples;
    }

    int pop(short[] dst, int frames) {
      int n = Math.min(frames, frames()) * ch;
      for (int i = 0; i < n; i++) dst[i] = buf[(head + i) % buf.length];
      head = (head + n) % buf.length;
      size -= n;
      return n / ch;
    }

    void drop(int frames) {
      dropSamples(Math.min(frames * ch, size));
    }

    private void dropSamples(int n) {
      n = Math.min(n, size);
      n += (ch - n % ch) % ch;
      n = Math.min(n, size);
      head = (head + n) % buf.length;
      size -= n;
    }
  }
}
