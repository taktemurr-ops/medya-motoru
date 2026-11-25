package com.gamestudio100.medya_motoru;

import android.app.Activity;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.media.projection.MediaProjectionManager;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.provider.Settings;

import androidx.annotation.NonNull;
import androidx.annotation.OptIn;
import androidx.media3.common.Effect;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.SonicAudioProcessor;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.Presentation;
import androidx.media3.effect.SpeedChangeEffect;
import androidx.media3.transformer.Composition;
import androidx.media3.transformer.DefaultEncoderFactory;
import androidx.media3.transformer.EditedMediaItem;
import androidx.media3.transformer.EditedMediaItemSequence;
import androidx.media3.transformer.Effects;
import androidx.media3.transformer.ExportException;
import androidx.media3.transformer.ExportResult;
import androidx.media3.transformer.Transformer;
import androidx.media3.transformer.VideoEncoderSettings;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.ByteOrder;
import java.nio.ShortBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import ai.onnxruntime.OnnxTensor;
import ai.onnxruntime.OrtEnvironment;
import ai.onnxruntime.OrtSession;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.PluginRegistry;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Medya motoru yerel eklentisi.
 *
 * <p>Video işleri (kesme, birleştirme, sıkıştırma, hız, ses çıkarma, slayt gösterisi) Media3
 * Transformer ile, ses çözme (WAV'a) MediaCodec ile, kare çıkarma MediaMetadataRetriever ile
 * yapılır. Hiçbiri ağ kullanmaz ve geniş depolama izni gerektirmez: girdiler uygulamanın
 * önbelleğine kopyalanmış dosyalardır. Yapay zekâ modelleri (ONNX) ONNX Runtime ile cihazda
 * çalıştırılır.
 */
@OptIn(markerClass = UnstableApi.class)
public class MedyaMotoruPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {
  private static final int REQ_SCREEN = 7302;
  private Activity activity;
  private ActivityPluginBinding activityBinding;
  private MethodChannel.Result pendingScreen;
  private Map<String, Object> pendingScreenArgs;
  private MethodChannel channel;
  private Context context;
  private final ExecutorService io = Executors.newSingleThreadExecutor();
  private final Handler main = new Handler(Looper.getMainLooper());
  private final Map<String, OrtSession> sessions = new HashMap<>();

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "medya_motoru/media");
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
  }

  // ------------------------------------------------------------------ etkinlik (ekran kaydı izni)

  @Override
  public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
    activity = binding.getActivity();
    activityBinding = binding;
    binding.addActivityResultListener(this);
  }

  @Override
  public void onDetachedFromActivityForConfigChanges() {
    onDetachedFromActivity();
  }

  @Override
  public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
    onAttachedToActivity(binding);
  }

  @Override
  public void onDetachedFromActivity() {
    if (activityBinding != null) activityBinding.removeActivityResultListener(this);
    activityBinding = null;
    activity = null;
  }

  @Override
  public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
    if (requestCode != REQ_SCREEN) return false;
    final MethodChannel.Result r = pendingScreen;
    final Map<String, Object> args = pendingScreenArgs;
    pendingScreen = null;
    pendingScreenArgs = null;
    if (r == null) return true;
    if (resultCode == Activity.RESULT_OK && data != null && args != null) {
      try {
        ScreenRecordService.start(context, resultCode, data, args);
        r.success(true);
      } catch (RuntimeException e) {
        r.error("screen", String.valueOf(e.getMessage()), null);
      }
    } else {
      r.success(false);
    }
    return true;
  }

  private void screenRecordStart(MethodCall call, MethodChannel.Result result) {
    if (activity == null) {
      result.success(false);
      return;
    }
    if (pendingScreen != null) {
      pendingScreen.success(false);
    }
    final Map<String, Object> args = new HashMap<>();
    for (String k : new String[] {"output", "width", "height", "dpi", "fps", "bitrate", "audio", "internal", "delayMs"}) {
      args.put(k, call.argument(k));
    }
    // Android 13+: kayıt bildirimindeki "Durdur" düğmesi için bildirim izni (isteğe bağlı).
    if (Build.VERSION.SDK_INT >= 33
        && activity.checkSelfPermission("android.permission.POST_NOTIFICATIONS") != android.content.pm.PackageManager.PERMISSION_GRANTED) {
      activity.requestPermissions(new String[] {"android.permission.POST_NOTIFICATIONS"}, REQ_SCREEN + 1);
    }
    final MediaProjectionManager mpm = (MediaProjectionManager) context.getSystemService(Context.MEDIA_PROJECTION_SERVICE);
    if (mpm == null) {
      result.success(false);
      return;
    }
    pendingScreen = result;
    pendingScreenArgs = args;
    activity.startActivityForResult(mpm.createScreenCaptureIntent(), REQ_SCREEN);
  }

  // ------------------------------------------------------------------ yardımcılar

  private interface Job {
    Object run() throws Exception;
  }

  private void background(final MethodChannel.Result result, final Job job) {
    io.execute(() -> {
      try {
        final Object value = job.run();
        main.post(() -> result.success(value));
      } catch (final Exception e) {
        main.post(() -> result.error("medya", String.valueOf(e.getMessage()), null));
      }
    });
  }

  private static String str(MethodCall call, String key) {
    final Object v = call.argument(key);
    if (v == null) throw new IllegalArgumentException(key);
    return v.toString();
  }

  private static long num(MethodCall call, String key, long fallback) {
    final Object v = call.argument(key);
    return v instanceof Number ? ((Number) v).longValue() : fallback;
  }

  private static double dbl(MethodCall call, String key, double fallback) {
    final Object v = call.argument(key);
    return v instanceof Number ? ((Number) v).doubleValue() : fallback;
  }

  private static boolean flag(MethodCall call, String key, boolean fallback) {
    final Object v = call.argument(key);
    return v instanceof Boolean ? (Boolean) v : fallback;
  }

  @SuppressWarnings("unchecked")
  private static List<String> list(MethodCall call, String key) {
    final Object v = call.argument(key);
    if (!(v instanceof List)) return Collections.emptyList();
    final List<String> out = new ArrayList<>();
    for (Object o : (List<Object>) v) out.add(String.valueOf(o));
    return out;
  }

  private static Uri uri(String path) {
    return Uri.fromFile(new File(path));
  }

  private void export(Transformer.Builder builder, Composition composition, String out,
      final MethodChannel.Result result) {
    //noinspection ResultOfMethodCallIgnored
    new File(out).delete();
    final Transformer transformer = builder
        .addListener(new Transformer.Listener() {
          @Override
          public void onCompleted(@NonNull Composition c, @NonNull ExportResult r) {
            result.success(true);
          }

          @Override
          public void onError(@NonNull Composition c, @NonNull ExportResult r, @NonNull ExportException e) {
            result.error("export", String.valueOf(e.getMessage()), null);
          }
        })
        .build();
    transformer.start(composition, out);
  }

  private static Composition single(EditedMediaItem item, boolean hasVideo, boolean hasAudio) {
    final List<EditedMediaItem> items = Collections.singletonList(item);
    final EditedMediaItemSequence seq;
    if (hasVideo && hasAudio) {
      seq = EditedMediaItemSequence.withAudioAndVideoFrom(items);
    } else if (hasVideo) {
      seq = EditedMediaItemSequence.withVideoFrom(items);
    } else {
      seq = EditedMediaItemSequence.withAudioFrom(items);
    }
    return new Composition.Builder(seq).build();
  }

  private Map<String, Object> probe(String path) throws Exception {
    final MediaMetadataRetriever r = new MediaMetadataRetriever();
    try {
      r.setDataSource(path);
      final Map<String, Object> m = new HashMap<>();
      m.put("durationMs", parse(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)));
      m.put("width", parse(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)));
      m.put("height", parse(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)));
      m.put("rotation", parse(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)));
      m.put("hasAudio", "yes".equals(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)));
      m.put("hasVideo", "yes".equals(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO)));
      return m;
    } finally {
      r.release();
    }
  }

  private static long parse(String s) {
    if (s == null) return 0;
    try {
      return Long.parseLong(s.trim());
    } catch (NumberFormatException e) {
      return 0;
    }
  }

  // ------------------------------------------------------------------ yöntemler

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    try {
      switch (call.method) {
        case "probe": {
          final String path = str(call, "path");
          background(result, () -> probe(path));
          break;
        }
        case "trim": {
          final String in = str(call, "input");
          final MediaItem mi = new MediaItem.Builder()
              .setUri(uri(in))
              .setClippingConfiguration(new MediaItem.ClippingConfiguration.Builder()
                  .setStartPositionMs(num(call, "startMs", 0))
                  .setEndPositionMs(num(call, "endMs", Long.MIN_VALUE))
                  .build())
              .build();
          final boolean audio = flag(call, "hasAudio", true);
          final boolean video = flag(call, "hasVideo", true);
          export(new Transformer.Builder(context), single(new EditedMediaItem.Builder(mi).build(), video, audio),
              str(call, "output"), result);
          break;
        }
        case "merge": {
          final List<String> inputs = list(call, "inputs");
          final int w = (int) num(call, "width", 0);
          final int h = (int) num(call, "height", 0);
          final List<EditedMediaItem> items = new ArrayList<>();
          for (String p : inputs) {
            final EditedMediaItem.Builder b = new EditedMediaItem.Builder(MediaItem.fromUri(uri(p)));
            if (w > 0 && h > 0) {
              b.setEffects(new Effects(Collections.<AudioProcessor>emptyList(),
                  Collections.<Effect>singletonList(
                      Presentation.createForWidthAndHeight(w, h, Presentation.LAYOUT_SCALE_TO_FIT))));
            }
            items.add(b.build());
          }
          final Composition c = new Composition.Builder(EditedMediaItemSequence.withAudioAndVideoFrom(items)).build();
          export(new Transformer.Builder(context).setVideoMimeType(MimeTypes.VIDEO_H264), c, str(call, "output"), result);
          break;
        }
        case "compress": {
          final int height = (int) num(call, "maxHeight", 720);
          final int kbps = (int) num(call, "bitrateKbps", 2000);
          final EditedMediaItem item = new EditedMediaItem.Builder(MediaItem.fromUri(uri(str(call, "input"))))
              .setEffects(new Effects(Collections.<AudioProcessor>emptyList(),
                  Collections.<Effect>singletonList(Presentation.createForShortSide(height))))
              .build();
          final DefaultEncoderFactory enc = new DefaultEncoderFactory.Builder(context)
              .setRequestedVideoEncoderSettings(new VideoEncoderSettings.Builder().setBitrate(kbps * 1000).build())
              .build();
          final Transformer.Builder tb = new Transformer.Builder(context)
              .setVideoMimeType(MimeTypes.VIDEO_H264)
              .setEncoderFactory(enc);
          export(tb, single(item, true, flag(call, "hasAudio", true)), str(call, "output"), result);
          break;
        }
        case "speed": {
          final float f = (float) dbl(call, "factor", 1.0);
          final boolean keepAudio = flag(call, "keepAudio", true) && flag(call, "hasAudio", true);
          final List<AudioProcessor> audio = new ArrayList<>();
          if (keepAudio) {
            final SonicAudioProcessor sonic = new SonicAudioProcessor();
            sonic.setSpeed(f);
            sonic.setPitch(1f);
            audio.add(sonic);
          }
          final EditedMediaItem item = new EditedMediaItem.Builder(MediaItem.fromUri(uri(str(call, "input"))))
              .setRemoveAudio(!keepAudio)
              .setEffects(new Effects(audio, Collections.<Effect>singletonList(new SpeedChangeEffect(f))))
              .build();
          export(new Transformer.Builder(context).setVideoMimeType(MimeTypes.VIDEO_H264),
              single(item, true, keepAudio), str(call, "output"), result);
          break;
        }
        case "extractAudio": {
          final EditedMediaItem item = new EditedMediaItem.Builder(MediaItem.fromUri(uri(str(call, "input"))))
              .setRemoveVideo(true)
              .build();
          export(new Transformer.Builder(context).setAudioMimeType(MimeTypes.AUDIO_AAC),
              single(item, false, true), str(call, "output"), result);
          break;
        }
        case "encodeM4a": {
          final EditedMediaItem item = new EditedMediaItem.Builder(MediaItem.fromUri(uri(str(call, "input"))))
              .setRemoveVideo(true)
              .build();
          export(new Transformer.Builder(context).setAudioMimeType(MimeTypes.AUDIO_AAC),
              single(item, false, true), str(call, "output"), result);
          break;
        }
        case "slideshow": {
          final List<String> images = list(call, "images");
          final long ms = num(call, "msPerImage", 2000);
          final int w = (int) num(call, "width", 1280);
          final int h = (int) num(call, "height", 720);
          final List<EditedMediaItem> items = new ArrayList<>();
          for (String p : images) {
            final MediaItem mi = new MediaItem.Builder().setUri(uri(p)).setImageDurationMs(ms).build();
            items.add(new EditedMediaItem.Builder(mi)
                .setFrameRate(30)
                .setEffects(new Effects(Collections.<AudioProcessor>emptyList(),
                    Collections.<Effect>singletonList(
                        Presentation.createForWidthAndHeight(w, h, Presentation.LAYOUT_SCALE_TO_FIT))))
                .build());
          }
          final Composition c = new Composition.Builder(EditedMediaItemSequence.withVideoFrom(items)).build();
          export(new Transformer.Builder(context).setVideoMimeType(MimeTypes.VIDEO_H264), c, str(call, "output"), result);
          break;
        }
        case "decodeToWav": {
          final String in = str(call, "input");
          final String out = str(call, "output");
          final int rate = (int) num(call, "sampleRate", 44100);
          final int ch = (int) num(call, "channels", 1);
          background(result, () -> {
            decodeToWav(in, out, rate, ch);
            return true;
          });
          break;
        }
        case "frames": {
          final String in = str(call, "input");
          final String dir = str(call, "outDir");
          final int count = (int) num(call, "count", 20);
          final int maxSide = (int) num(call, "maxSide", 480);
          final long startMs = num(call, "startMs", 0);
          final long endMs = num(call, "endMs", -1);
          background(result, () -> frames(in, dir, count, maxSide, startMs, endMs));
          break;
        }
        case "saveRingtone": {
          final String in = str(call, "path");
          final String name = str(call, "name");
          background(result, () -> saveRingtone(in, name));
          break;
        }
        case "onnxRun": {
          final String model = str(call, "model");
          final Object raw = call.argument("input");
          if (!(raw instanceof float[])) throw new IllegalArgumentException("input");
          final float[] data = (float[]) raw;
          final List<String> dims = list(call, "shape");
          final long[] shape = new long[dims.size()];
          for (int i = 0; i < shape.length; i++) shape[i] = Long.parseLong(dims.get(i));
          background(result, () -> onnxRun(model, data, shape));
          break;
        }
        case "screenRecordStart": {
          screenRecordStart(call, result);
          break;
        }
        case "screenRecordStop": {
          ScreenRecordService.stop(context);
          result.success(true);
          break;
        }
        case "screenRecordPause": {
          result.success(ScreenRecordService.pause(flag(call, "pause", true)));
          break;
        }
        case "screenAudioSupport": {
          result.success(ScreenRecordService.appAudioSupported());
          break;
        }
        case "screenRecordStatus": {
          result.success(ScreenRecordService.status());
          break;
        }
        case "openSoundSettings": {
          final Intent i = new Intent(Settings.ACTION_SOUND_SETTINGS);
          i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
          context.startActivity(i);
          result.success(true);
          break;
        }
        default:
          result.notImplemented();
      }
    } catch (Exception e) {
      result.error("medya", String.valueOf(e.getMessage()), null);
    }
  }

  // ------------------------------------------------------------------ ONNX

  /** Modeli bir kez yükler (önbellek), tek girdiyle çalıştırır, ilk çıktıyı döndürür. */
  private float[] onnxRun(String model, float[] data, long[] shape) throws Exception {
    final OrtEnvironment env = OrtEnvironment.getEnvironment();
    OrtSession s = sessions.get(model);
    if (s == null) {
      s = env.createSession(model, new OrtSession.SessionOptions());
      sessions.put(model, s);
    }
    final String in = s.getInputNames().iterator().next();
    try (OnnxTensor t = OnnxTensor.createTensor(env, FloatBuffer.wrap(data), shape);
         OrtSession.Result r = s.run(Collections.singletonMap(in, t))) {
      final OnnxTensor o = (OnnxTensor) r.get(0);
      final FloatBuffer fb = o.getFloatBuffer();
      final float[] out = new float[fb.remaining()];
      fb.get(out);
      return out;
    }
  }

  // ------------------------------------------------------------------ WAV

  /** Herhangi bir ses/video dosyasının ses izini 16 bit PCM WAV'a çözer. */
  private static void decodeToWav(String input, String output, int outRate, int outCh) throws Exception {
    final MediaExtractor ex = new MediaExtractor();
    MediaCodec codec = null;
    try {
      ex.setDataSource(input);
      int track = -1;
      MediaFormat fmt = null;
      for (int i = 0; i < ex.getTrackCount(); i++) {
        final MediaFormat f = ex.getTrackFormat(i);
        final String mime = f.getString(MediaFormat.KEY_MIME);
        if (mime != null && mime.startsWith("audio/")) {
          track = i;
          fmt = f;
          break;
        }
      }
      if (track < 0) throw new IllegalStateException("no audio");
      ex.selectTrack(track);
      int srcRate = fmt.getInteger(MediaFormat.KEY_SAMPLE_RATE);
      int srcCh = fmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
      codec = MediaCodec.createDecoderByType(fmt.getString(MediaFormat.KEY_MIME));
      codec.configure(fmt, null, null, 0);
      codec.start();
      final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
      final ByteArrayOutputStream raw = new ByteArrayOutputStream();
      boolean inEos = false;
      boolean outEos = false;
      while (!outEos) {
        if (!inEos) {
          final int ii = codec.dequeueInputBuffer(10000);
          if (ii >= 0) {
            final ByteBuffer buf = codec.getInputBuffer(ii);
            final int n = buf == null ? -1 : ex.readSampleData(buf, 0);
            if (n < 0) {
              codec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
              inEos = true;
            } else {
              codec.queueInputBuffer(ii, 0, n, ex.getSampleTime(), 0);
              ex.advance();
            }
          }
        }
        final int oi = codec.dequeueOutputBuffer(info, 10000);
        if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
          final MediaFormat of = codec.getOutputFormat();
          srcRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE);
          srcCh = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
        } else if (oi >= 0) {
          final ByteBuffer ob = codec.getOutputBuffer(oi);
          if (ob != null && info.size > 0) {
            ob.position(info.offset);
            ob.limit(info.offset + info.size);
            final ShortBuffer sb = ob.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();
            final int frames = sb.remaining() / Math.max(1, srcCh);
            final byte[] chunk = new byte[frames * outCh * 2];
            int o = 0;
            for (int f = 0; f < frames; f++) {
              final int base = f * srcCh;
              if (outCh == 1) {
                int sum = 0;
                for (int c = 0; c < srcCh; c++) sum += sb.get(base + c);
                final int v = sum / Math.max(1, srcCh);
                chunk[o++] = (byte) (v & 0xff);
                chunk[o++] = (byte) ((v >> 8) & 0xff);
              } else {
                for (int c = 0; c < outCh; c++) {
                  final int v = sb.get(base + Math.min(c, srcCh - 1));
                  chunk[o++] = (byte) (v & 0xff);
                  chunk[o++] = (byte) ((v >> 8) & 0xff);
                }
              }
            }
            raw.write(chunk, 0, o);
          }
          codec.releaseOutputBuffer(oi, false);
          if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outEos = true;
        }
      }
      byte[] pcm = raw.toByteArray();
      if (srcRate != outRate) pcm = resample(pcm, outCh, srcRate, outRate);
      writeWav(output, pcm, outRate, outCh);
    } finally {
      if (codec != null) {
        try {
          codec.stop();
        } catch (Exception ignored) {
        }
        codec.release();
      }
      ex.release();
    }
  }

  private static byte[] resample(byte[] pcm, int ch, int from, int to) {
    final ShortBuffer src = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();
    final int inFrames = src.remaining() / ch;
    final int outFrames = (int) ((long) inFrames * to / from);
    final byte[] out = new byte[outFrames * ch * 2];
    final ShortBuffer dst = ByteBuffer.wrap(out).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer();
    for (int i = 0; i < outFrames; i++) {
      final double pos = (double) i * from / to;
      final int a = (int) pos;
      final int b = Math.min(a + 1, inFrames - 1);
      final double t = pos - a;
      for (int c = 0; c < ch; c++) {
        final double v = src.get(a * ch + c) * (1 - t) + src.get(b * ch + c) * t;
        dst.put(i * ch + c, (short) Math.max(-32768, Math.min(32767, Math.round(v))));
      }
    }
    return out;
  }

  private static void writeWav(String path, byte[] pcm, int rate, int ch) throws Exception {
    final ByteBuffer h = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN);
    h.put(new byte[] {'R', 'I', 'F', 'F'});
    h.putInt(36 + pcm.length);
    h.put(new byte[] {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    h.putInt(16);
    h.putShort((short) 1);
    h.putShort((short) ch);
    h.putInt(rate);
    h.putInt(rate * ch * 2);
    h.putShort((short) (ch * 2));
    h.putShort((short) 16);
    h.put(new byte[] {'d', 'a', 't', 'a'});
    h.putInt(pcm.length);
    try (FileOutputStream fo = new FileOutputStream(path)) {
      fo.write(h.array());
      fo.write(pcm);
    }
  }

  // ------------------------------------------------------------------ kareler

  private static List<String> frames(String input, String dir, int count, int maxSide, long startMs, long endMs)
      throws Exception {
    final MediaMetadataRetriever r = new MediaMetadataRetriever();
    final List<String> out = new ArrayList<>();
    try {
      r.setDataSource(input);
      final long dur = parse(r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION));
      final long end = endMs > 0 ? Math.min(endMs, dur) : dur;
      final long start = Math.max(0, Math.min(startMs, end));
      final int n = Math.max(1, count);
      //noinspection ResultOfMethodCallIgnored
      new File(dir).mkdirs();
      for (int i = 0; i < n; i++) {
        final long t = start + (end - start) * i / n;
        final Bitmap bmp = r.getFrameAtTime(t * 1000, MediaMetadataRetriever.OPTION_CLOSEST);
        if (bmp == null) continue;
        final float s = Math.min(1f, (float) maxSide / Math.max(bmp.getWidth(), bmp.getHeight()));
        final Bitmap scaled = s < 1f
            ? Bitmap.createScaledBitmap(bmp, Math.max(1, Math.round(bmp.getWidth() * s)),
                Math.max(1, Math.round(bmp.getHeight() * s)), true)
            : bmp;
        final File f = new File(dir, String.format(java.util.Locale.ROOT, "frame_%03d.jpg", i));
        try (FileOutputStream fo = new FileOutputStream(f)) {
          scaled.compress(Bitmap.CompressFormat.JPEG, 88, fo);
        }
        out.add(f.getAbsolutePath());
        if (scaled != bmp) scaled.recycle();
        bmp.recycle();
      }
    } finally {
      r.release();
    }
    return out;
  }

  // ------------------------------------------------------------------ zil sesi

  /** Dosyayı Ringtones klasörüne ekler (Android 10+, izin gerektirmez). */
  private boolean saveRingtone(String path, String name) throws Exception {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false;
    final ContentResolver cr = context.getContentResolver();
    final ContentValues v = new ContentValues();
    v.put(MediaStore.Audio.Media.DISPLAY_NAME, name);
    v.put(MediaStore.Audio.Media.MIME_TYPE, name.endsWith(".wav") ? "audio/wav" : "audio/mp4");
    v.put(MediaStore.Audio.Media.RELATIVE_PATH, "Ringtones/");
    v.put(MediaStore.Audio.Media.IS_RINGTONE, true);
    v.put(MediaStore.Audio.Media.IS_PENDING, 1);
    final Uri target = cr.insert(MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), v);
    if (target == null) return false;
    try (InputStream in = new FileInputStream(path); OutputStream os = cr.openOutputStream(target)) {
      if (os == null) return false;
      final byte[] buf = new byte[64 * 1024];
      int n;
      while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
    }
    final ContentValues done = new ContentValues();
    done.put(MediaStore.Audio.Media.IS_PENDING, 0);
    cr.update(target, done, null, null);
    return true;
  }
}
