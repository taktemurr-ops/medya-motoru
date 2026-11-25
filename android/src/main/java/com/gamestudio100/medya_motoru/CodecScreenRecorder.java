package com.gamestudio100.medya_motoru;

import android.annotation.SuppressLint;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.media.MediaRecorder;
import android.media.projection.MediaProjection;
import android.os.Bundle;
import android.os.Handler;
import android.view.Surface;

import androidx.annotation.RequiresApi;

import java.io.File;
import java.nio.ByteBuffer;

/**
 * Uygulama sesli ekran kaydı (Android 10+, API 29): MediaProjection ile
 * AudioPlaybackCapture (oynayan uygulamaların sesi) + isteğe bağlı mikrofon,
 * 16 bit PCM olarak karıştırılır ve AAC'ye; ekran H.264'e kodlanır, ikisi
 * MediaMuxer ile MP4'e yazılır. MediaRecorder uygulama sesini alamadığı için
 * yalnız bu kip MediaCodec kullanır; diğer kayıtlar eskisi gibi MediaRecorder ile.
 *
 * Ses yakalamayı engelleyen uygulamalar (allowAudioPlaybackCapture=false,
 * ALLOW_CAPTURE_BY_NONE/SYSTEM, aramalar) kayıtta sessiz kalır; hiç ses
 * gelmezse "internal_silent" uyarısı verilir. Uygulama sesi kaydedici
 * kurulamazsa kayıt mikrofonla ya da sessiz sürer ("internal_unavailable").
 */
@RequiresApi(29)
final class CodecScreenRecorder {
  private static final int RATE = 44100;
  private static final int CHUNK_FRAMES = 1024;
  private static final long TIMEOUT_US = 10_000;

  private final MediaProjection projection;
  private final String out;
  private final int width, height, fps, bitrate, dpi;
  private final boolean wantMic;

  private MediaCodec video, audio;
  private Surface inputSurface;
  private VirtualDisplay display;
  private AudioRecord appRec, micRec;
  private MediaMuxer muxer;
  private int videoTrack = -1, audioTrack = -1;
  private boolean muxerStarted;
  private boolean hasAudio;
  private long videoSamples;

  private Thread videoThread, audioThread;
  private volatile boolean running;
  private volatile boolean paused;
  private volatile boolean needKey = true;
  private volatile long baseUs;
  private volatile long pausedTotalUs, pauseStartUs, resumeAtUs;
  private volatile int appPeak;
  private long lastVideoPts = -1, lastAudioPts = -1;

  /** "internal_unavailable" ya da "internal_silent"; yoksa null. */
  volatile String warning;

  CodecScreenRecorder(MediaProjection projection, String out, int width, int height, int fps, int bitrate, int dpi, boolean mic) {
    this.projection = projection;
    this.out = out;
    this.width = width;
    this.height = height;
    this.fps = fps;
    this.bitrate = bitrate;
    this.dpi = dpi;
    this.wantMic = mic;
  }

  /** Kodlayıcıları, ses kaynaklarını ve sanal ekranı kurup kaydı başlatır. */
  @SuppressLint("MissingPermission")
  void start(Handler handler) throws Exception {
    // Ses: uygulama sesi (stereo) + mikrofon (mono). İzin servis tarafında denetlenir.
    int minStereo = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT);
    int minMono = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
    try {
      AudioPlaybackCaptureConfiguration cfg = new AudioPlaybackCaptureConfiguration.Builder(projection)
          .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
          .addMatchingUsage(AudioAttributes.USAGE_GAME)
          .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
          .build();
      AudioRecord r = new AudioRecord.Builder()
          .setAudioFormat(new AudioFormat.Builder()
              .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
              .setSampleRate(RATE)
              .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
              .build())
          .setBufferSizeInBytes(Math.max(minStereo, CHUNK_FRAMES * 4) * 2)
          .setAudioPlaybackCaptureConfig(cfg)
          .build();
      if (r.getState() == AudioRecord.STATE_INITIALIZED) {
        appRec = r;
      } else {
        r.release();
      }
    } catch (RuntimeException e) {
      appRec = null;
    }
    if (appRec == null) warning = "internal_unavailable";
    if (wantMic) {
      try {
        AudioRecord m = new AudioRecord(MediaRecorder.AudioSource.MIC, RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, Math.max(minMono, CHUNK_FRAMES * 2) * 2);
        if (m.getState() == AudioRecord.STATE_INITIALIZED) {
          micRec = m;
        } else {
          m.release();
        }
      } catch (RuntimeException e) {
        micRec = null;
      }
    }
    hasAudio = appRec != null || micRec != null;

    MediaFormat vf = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height);
    vf.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
    vf.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
    vf.setInteger(MediaFormat.KEY_FRAME_RATE, fps);
    vf.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
    // Ekran durağanken de kare üret (ses ile görüntü eşit uzunlukta kalsın).
    vf.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 1_000_000L / Math.max(1, fps));
    video = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
    video.configure(vf, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
    inputSurface = video.createInputSurface();

    if (hasAudio) {
      MediaFormat af = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, RATE, 2);
      af.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
      af.setInteger(MediaFormat.KEY_BIT_RATE, 160_000);
      af.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, CHUNK_FRAMES * 4 * 2);
      audio = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
      audio.configure(af, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
    }

    muxer = new MediaMuxer(out, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
    video.start();
    if (audio != null) audio.start();
    baseUs = System.nanoTime() / 1000;
    running = true;
    display = projection.createVirtualDisplay("medya-screen-record", width, height, dpi,
        DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, inputSurface, null, handler);
    if (appRec != null) appRec.startRecording();
    if (micRec != null) micRec.startRecording();
    videoThread = new Thread(this::videoLoop, "medya-rec-video");
    videoThread.start();
    if (audio != null) {
      audioThread = new Thread(this::audioLoop, "medya-rec-audio");
      audioThread.start();
    }
  }

  boolean appAudioActive() {
    return appRec != null;
  }

  void pause(boolean p) {
    long now = System.nanoTime() / 1000;
    if (p && !paused) {
      pauseStartUs = now;
      paused = true;
    } else if (!p && paused) {
      pausedTotalUs += now - pauseStartUs;
      resumeAtUs = now;
      needKey = true;
      paused = false;
      requestKeyFrame();
    }
  }

  private void requestKeyFrame() {
    try {
      Bundle b = new Bundle();
      b.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
      if (video != null) video.setParameters(b);
    } catch (RuntimeException ignored) {
    }
  }

  private synchronized void addTrack(MediaFormat f, boolean isVideo) {
    if (muxerStarted) return;
    if (isVideo) {
      videoTrack = muxer.addTrack(f);
    } else {
      audioTrack = muxer.addTrack(f);
    }
    if (videoTrack >= 0 && (!hasAudio || audioTrack >= 0)) {
      muxer.start();
      muxerStarted = true;
      needKey = true;
      requestKeyFrame();
    }
  }

  private synchronized boolean write(boolean isVideo, ByteBuffer buf, MediaCodec.BufferInfo info) {
    if (!muxerStarted) return false;
    long pts = info.presentationTimeUs;
    if (isVideo) {
      if (pts <= lastVideoPts) pts = lastVideoPts + 1;
      lastVideoPts = pts;
    } else {
      if (pts <= lastAudioPts) pts = lastAudioPts + 1;
      lastAudioPts = pts;
    }
    info.presentationTimeUs = pts;
    muxer.writeSampleData(isVideo ? videoTrack : audioTrack, buf, info);
    if (isVideo) videoSamples++;
    return true;
  }

  private void videoLoop() {
    MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
    while (true) {
      int idx;
      try {
        idx = video.dequeueOutputBuffer(info, TIMEOUT_US);
      } catch (RuntimeException e) {
        break;
      }
      if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        addTrack(video.getOutputFormat(), true);
        continue;
      }
      if (idx < 0) continue;
      ByteBuffer buf = video.getOutputBuffer(idx);
      boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
      boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
      boolean key = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
      long frameUs = info.presentationTimeUs;
      boolean drop = config || buf == null || info.size <= 0 || paused || frameUs < resumeAtUs;
      if (!drop && needKey && !key) drop = true;
      if (!drop) {
        info.presentationTimeUs = Math.max(0, frameUs - baseUs - pausedTotalUs);
        buf.position(info.offset);
        buf.limit(info.offset + info.size);
        if (write(true, buf, info)) {
          if (key) needKey = false;
        } else {
          needKey = true;
        }
      }
      video.releaseOutputBuffer(idx, false);
      if (eos) break;
    }
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

  private void audioLoop() {
    short[] app = appRec != null ? new short[CHUNK_FRAMES * 2] : null;
    short[] mic = micRec != null ? new short[CHUNK_FRAMES] : null;
    short[] mixed = new short[CHUNK_FRAMES * 2];
    byte[] bytes = new byte[CHUNK_FRAMES * 4];
    long frames = 0;
    long startUs = -1;
    MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
    while (running) {
      int n = CHUNK_FRAMES;
      if (app != null) {
        int r = appRec.read(app, 0, app.length);
        if (r <= 0) {
          drainAudio(info, false);
          continue;
        }
        n = r / 2;
      }
      if (mic != null) {
        int got = 0;
        while (got < n && running) {
          int r = micRec.read(mic, got, n - got);
          if (r <= 0) break;
          got += r;
        }
        for (int i = got; i < n; i++) mic[i] = 0;
      }
      if (startUs < 0) startUs = System.nanoTime() / 1000 - baseUs;
      if (paused) {
        drainAudio(info, false);
        continue;
      }
      if (app != null) {
        int peak = appPeak;
        for (int i = 0; i < n * 2; i++) {
          int a = Math.abs((int) app[i]);
          if (a > peak) peak = a;
        }
        appPeak = peak;
      }
      mix(app, mic, mixed, n);
      for (int i = 0; i < n * 2; i++) {
        bytes[i * 2] = (byte) (mixed[i] & 0xff);
        bytes[i * 2 + 1] = (byte) ((mixed[i] >> 8) & 0xff);
      }
      long pts = Math.max(0, startUs) + frames * 1_000_000L / RATE;
      queueAudio(bytes, n * 4, pts, false, info);
      frames += n;
      drainAudio(info, false);
    }
    long pts = Math.max(0, startUs) + frames * 1_000_000L / RATE;
    queueAudio(bytes, 0, pts, true, info);
    drainAudio(info, true);
  }

  private void queueAudio(byte[] data, int len, long pts, boolean eos, MediaCodec.BufferInfo info) {
    for (int tries = 0; tries < 200; tries++) {
      int idx;
      try {
        idx = audio.dequeueInputBuffer(TIMEOUT_US);
      } catch (RuntimeException e) {
        return;
      }
      if (idx >= 0) {
        ByteBuffer in = audio.getInputBuffer(idx);
        int size = 0;
        if (in != null && len > 0) {
          in.clear();
          size = Math.min(len, in.remaining());
          in.put(data, 0, size);
        }
        audio.queueInputBuffer(idx, 0, size, pts, eos ? MediaCodec.BUFFER_FLAG_END_OF_STREAM : 0);
        return;
      }
      drainAudio(info, false);
    }
  }

  private void drainAudio(MediaCodec.BufferInfo info, boolean untilEos) {
    int idle = 0;
    while (true) {
      int idx;
      try {
        idx = audio.dequeueOutputBuffer(info, untilEos ? TIMEOUT_US : 0);
      } catch (RuntimeException e) {
        return;
      }
      if (idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
        addTrack(audio.getOutputFormat(), false);
        continue;
      }
      if (idx < 0) {
        if (!untilEos || ++idle > 100) return;
        continue;
      }
      ByteBuffer buf = audio.getOutputBuffer(idx);
      boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
      boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
      if (!config && buf != null && info.size > 0) {
        buf.position(info.offset);
        buf.limit(info.offset + info.size);
        write(false, buf, info);
      }
      audio.releaseOutputBuffer(idx, false);
      if (eos) return;
    }
  }

  /**
   * Kaydı bitirir. Dönen: null (tamam), "empty" (hiç kare yazılmadı; dosya
   * silinir). Uyarı varsa {@link #warning} alanında kalır.
   */
  String stop() {
    running = false;
    paused = false;
    if (display != null) {
      display.release();
      display = null;
    }
    try {
      if (video != null) video.signalEndOfInputStream();
    } catch (RuntimeException ignored) {
    }
    join(videoThread);
    join(audioThread);
    for (AudioRecord r : new AudioRecord[] {appRec, micRec}) {
      if (r == null) continue;
      try {
        r.stop();
      } catch (RuntimeException ignored) {
      }
      r.release();
    }
    for (MediaCodec c : new MediaCodec[] {video, audio}) {
      if (c == null) continue;
      try {
        c.stop();
      } catch (RuntimeException ignored) {
      }
      c.release();
    }
    video = null;
    audio = null;
    if (inputSurface != null) {
      inputSurface.release();
      inputSurface = null;
    }
    boolean ok = false;
    synchronized (this) {
      if (muxer != null) {
        try {
          if (muxerStarted && videoSamples > 0) {
            muxer.stop();
            ok = true;
          }
        } catch (RuntimeException ignored) {
          ok = false;
        }
        muxer.release();
        muxer = null;
      }
    }
    if (!ok) {
      //noinspection ResultOfMethodCallIgnored
      new File(out).delete();
      return "empty";
    }
    if (appRec != null && appPeak == 0 && warning == null) warning = "internal_silent";
    return null;
  }

  private static void join(Thread t) {
    if (t == null) return;
    try {
      t.join(3000);
    } catch (InterruptedException e) {
      Thread.currentThread().interrupt();
    }
  }
}
