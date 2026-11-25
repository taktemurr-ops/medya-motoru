package com.gamestudio100.medya_motoru;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaRecorder;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;

import java.io.File;
import java.util.HashMap;
import java.util.Map;

/**
 * Ekran kaydı ön plan hizmeti (foregroundServiceType="mediaProjection").
 * Kullanıcının sistem penceresinde verdiği izinle (MediaProjection) ekranı
 * MediaRecorder'a (H.264 + isteğe bağlı mikrofon AAC) yönlendirir. Bildirimde
 * "Durdur" düğmesi vardır. Dosya, Dart tarafının verdiği uygulama klasörüne yazılır.
 *
 * "Uygulama sesi" açıksa (Android 10+, mikrofon izniyle) kayıt
 * {@link CodecScreenRecorder} ile yapılır (AudioPlaybackCapture + isteğe bağlı
 * mikrofon, MediaCodec + MediaMuxer). Kurulamazsa eski yola (MediaRecorder)
 * düşülür ve uyarı bildirilir.
 */
public class ScreenRecordService extends Service {
  static final String ACTION_START = "com.gamestudio100.medya_motoru.SCREEN_START";
  static final String ACTION_STOP = "com.gamestudio100.medya_motoru.SCREEN_STOP";
  private static final String CHANNEL = "medya_screen_record";
  private static final int NOTIFICATION_ID = 7301;

  private static volatile boolean recording, paused, waiting;
  private static volatile long startedAt, pausedAt, pausedTotal;
  private static volatile String path, error, warning;
  private static volatile boolean appAudio;
  private static ScreenRecordService instance;

  private final Handler handler = new Handler(Looper.getMainLooper());
  private MediaProjection projection;
  private VirtualDisplay display;
  private MediaRecorder recorder;
  private CodecScreenRecorder codec;

  static void start(Context c, int resultCode, Intent data, Map<String, Object> args) {
    Intent i = new Intent(c, ScreenRecordService.class).setAction(ACTION_START);
    i.putExtra("code", resultCode);
    i.putExtra("data", data);
    i.putExtra("output", String.valueOf(args.get("output")));
    i.putExtra("width", intOf(args.get("width"), 720));
    i.putExtra("height", intOf(args.get("height"), 1280));
    i.putExtra("dpi", intOf(args.get("dpi"), 320));
    i.putExtra("fps", intOf(args.get("fps"), 30));
    i.putExtra("bitrate", intOf(args.get("bitrate"), 6000000));
    i.putExtra("audio", Boolean.TRUE.equals(args.get("audio")));
    i.putExtra("internal", Boolean.TRUE.equals(args.get("internal")));
    i.putExtra("delayMs", intOf(args.get("delayMs"), 0));
    error = null;
    warning = null;
    appAudio = false;
    waiting = true;
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      c.startForegroundService(i);
    } else {
      c.startService(i);
    }
  }

  static void stop(Context c) {
    ScreenRecordService s = instance;
    if (s != null) {
      s.handler.post(s::finish);
    } else {
      waiting = false;
      recording = false;
    }
  }

  static boolean pause(boolean p) {
    ScreenRecordService s = instance;
    if (s != null && s.codec != null && recording) {
      if (p && !paused) {
        s.codec.pause(true);
        paused = true;
        pausedAt = SystemClock.elapsedRealtime();
      } else if (!p && paused) {
        s.codec.pause(false);
        paused = false;
        pausedTotal += SystemClock.elapsedRealtime() - pausedAt;
      }
      return true;
    }
    if (s == null || s.recorder == null || !recording || Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false;
    try {
      if (p && !paused) {
        s.recorder.pause();
        paused = true;
        pausedAt = SystemClock.elapsedRealtime();
      } else if (!p && paused) {
        s.recorder.resume();
        paused = false;
        pausedTotal += SystemClock.elapsedRealtime() - pausedAt;
      }
      return true;
    } catch (RuntimeException e) {
      return false;
    }
  }

  static Map<String, Object> status() {
    Map<String, Object> m = new HashMap<>();
    m.put("recording", recording);
    m.put("paused", paused);
    m.put("waiting", waiting);
    long now = SystemClock.elapsedRealtime();
    long el = recording ? now - startedAt - pausedTotal - (paused ? now - pausedAt : 0) : 0;
    m.put("elapsedMs", Math.max(0, el));
    m.put("path", path);
    m.put("error", error);
    m.put("warning", warning);
    m.put("appAudio", appAudio);
    return m;
  }

  /** Uygulama sesi kaydı (AudioPlaybackCapture) bu sürümde var mı? */
  static boolean appAudioSupported() {
    return Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q;
  }

  private static int intOf(Object o, int fallback) {
    return o instanceof Number ? ((Number) o).intValue() : fallback;
  }

  @Override
  public IBinder onBind(Intent intent) {
    return null;
  }

  private Notification notification() {
    NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm != null) {
      NotificationChannel ch = new NotificationChannel(CHANNEL, getString(R.string.medya_rec_channel), NotificationManager.IMPORTANCE_LOW);
      nm.createNotificationChannel(ch);
    }
    int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ? PendingIntent.FLAG_IMMUTABLE : 0);
    PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, ScreenRecordService.class).setAction(ACTION_STOP), flags);
    Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
    PendingIntent open = launch == null ? null : PendingIntent.getActivity(this, 2, launch, flags);
    Notification.Builder b = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ? new Notification.Builder(this, CHANNEL)
        : new Notification.Builder(this);
    b.setSmallIcon(android.R.drawable.presence_video_online)
        .setContentTitle(getString(R.string.medya_rec_running))
        .setOngoing(true)
        .addAction(new Notification.Action.Builder(android.R.drawable.ic_media_pause, getString(R.string.medya_rec_stop), stop).build());
    if (open != null) b.setContentIntent(open);
    return b.build();
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    if (intent == null || ACTION_STOP.equals(intent.getAction())) {
      finish();
      return START_NOT_STICKY;
    }
    instance = this;
    Notification n = notification();
    // Android 11+: ön plan hizmetinde ses kaydı için "microphone" türü gerekir
    // (uygulama arka plandayken mikrofon/uygulama sesi sessiz kalmasın).
    boolean wantsAudio = intent.getBooleanExtra("audio", false) || intent.getBooleanExtra("internal", false);
    boolean micType = wantsAudio && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
        && checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        int type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION;
        if (micType) {
          try {
            startForeground(NOTIFICATION_ID, n, type | ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
          } catch (RuntimeException e) {
            startForeground(NOTIFICATION_ID, n, type);
          }
        } else {
          startForeground(NOTIFICATION_ID, n, type);
        }
      } else {
        startForeground(NOTIFICATION_ID, n);
      }
    } catch (RuntimeException e) {
      error = "foreground: " + e.getMessage();
      waiting = false;
      stopSelf();
      return START_NOT_STICKY;
    }
    final int code = intent.getIntExtra("code", 0);
    final Intent data = Build.VERSION.SDK_INT >= 33
        ? intent.getParcelableExtra("data", Intent.class)
        : legacyData(intent);
    MediaProjectionManager mpm = (MediaProjectionManager) getSystemService(Context.MEDIA_PROJECTION_SERVICE);
    if (mpm == null || data == null) {
      fail("projection");
      return START_NOT_STICKY;
    }
    try {
      projection = mpm.getMediaProjection(code, data);
    } catch (RuntimeException e) {
      projection = null;
    }
    if (projection == null) {
      fail("projection");
      return START_NOT_STICKY;
    }
    projection.registerCallback(new MediaProjection.Callback() {
      @Override
      public void onStop() {
        handler.post(ScreenRecordService.this::finish);
      }
    }, handler);
    final Intent args = intent;
    handler.postDelayed(() -> begin(args), Math.max(0, intent.getIntExtra("delayMs", 0)));
    return START_NOT_STICKY;
  }

  @SuppressWarnings("deprecation")
  private static Intent legacyData(Intent i) {
    return i.getParcelableExtra("data");
  }

  private void fail(String why) {
    error = why;
    finish();
  }

  @SuppressWarnings("deprecation")
  private void begin(Intent a) {
    if (projection == null) return;
    String out = a.getStringExtra("output");
    int w = a.getIntExtra("width", 720), h = a.getIntExtra("height", 1280);
    int fps = a.getIntExtra("fps", 30), bitrate = a.getIntExtra("bitrate", 6000000), dpi = a.getIntExtra("dpi", 320);
    boolean permitted = checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
    boolean audio = a.getBooleanExtra("audio", false) && permitted;
    if (a.getBooleanExtra("internal", false)) {
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
        warning = "internal_old";
      } else if (!permitted) {
        warning = "internal_perm";
      } else if (beginCodec(out, w, h, fps, bitrate, dpi, audio)) {
        return;
      }
      // Kurulamadı: eski yol (MediaRecorder, isteğe bağlı mikrofon).
    }
    try {
      recorder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ? new MediaRecorder(this) : new MediaRecorder();
      if (audio) recorder.setAudioSource(MediaRecorder.AudioSource.MIC);
      recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE);
      recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
      recorder.setOutputFile(out);
      recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264);
      recorder.setVideoSize(w, h);
      recorder.setVideoFrameRate(fps);
      recorder.setVideoEncodingBitRate(bitrate);
      if (audio) {
        recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
        recorder.setAudioSamplingRate(44100);
        recorder.setAudioEncodingBitRate(128000);
      }
      recorder.prepare();
      display = projection.createVirtualDisplay("medya-screen-record", w, h, dpi,
          DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, recorder.getSurface(), null, handler);
      recorder.start();
      path = out;
      startedAt = SystemClock.elapsedRealtime();
      pausedTotal = 0;
      paused = false;
      recording = true;
      waiting = false;
    } catch (Exception e) {
      error = "recorder: " + e.getMessage();
      if (out != null) {
        //noinspection ResultOfMethodCallIgnored
        new File(out).delete();
      }
      finish();
    }
  }

  /** Uygulama sesli kayıt (API 29+). Başarısızsa false; çağıran eski yola döner. */
  private boolean beginCodec(String out, int w, int h, int fps, int bitrate, int dpi, boolean mic) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false;
    CodecScreenRecorder c = new CodecScreenRecorder(projection, out, w, h, fps, bitrate, dpi, mic);
    try {
      c.start(handler);
    } catch (Exception e) {
      c.stop();
      warning = "internal_unavailable";
      return false;
    }
    codec = c;
    appAudio = c.appAudioActive();
    if (c.warning != null) warning = c.warning;
    path = out;
    startedAt = SystemClock.elapsedRealtime();
    pausedTotal = 0;
    paused = false;
    recording = true;
    waiting = false;
    return true;
  }

  private void finish() {
    boolean was = recording;
    recording = false;
    paused = false;
    waiting = false;
    handler.removeCallbacksAndMessages(null);
    if (codec != null) {
      CodecScreenRecorder c = codec;
      codec = null;
      String r = c.stop();
      if ("empty".equals(r)) error = "empty";
      if (c.warning != null) warning = c.warning;
    }
    if (recorder != null) {
      try {
        if (was) recorder.stop();
      } catch (RuntimeException e) {
        // Hiç kare yazılmadıysa stop() hata verir: yarım dosyayı sil.
        error = "empty";
        if (path != null) {
          //noinspection ResultOfMethodCallIgnored
          new File(path).delete();
        }
      }
      recorder.release();
      recorder = null;
    }
    if (display != null) {
      display.release();
      display = null;
    }
    if (projection != null) {
      MediaProjection p = projection;
      projection = null;
      try {
        p.stop();
      } catch (RuntimeException ignored) {
      }
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE);
    } else {
      stopForeground(true);
    }
    instance = null;
    stopSelf();
  }

  @Override
  public void onDestroy() {
    if (recording || projection != null) finish();
    super.onDestroy();
  }
}
