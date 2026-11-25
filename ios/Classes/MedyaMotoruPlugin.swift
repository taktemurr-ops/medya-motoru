// Medya motoru: iOS yerel ortam eklentisi.
//
// Video kesme, birleştirme, sıkıştırma, hız, ses çıkarma ve slayt gösterisi
// AVFoundation ile; ses çözme (WAV) AVAssetReader ile; kare çıkarma
// AVAssetImageGenerator ile yapılır. Ağ kullanılmaz.
import AVFoundation
import Flutter
import UIKit
import onnxruntime_objc

struct MedyaError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

public class MedyaMotoruPlugin: NSObject, FlutterPlugin {
  private let work = DispatchQueue(label: "medya_motoru.work", qos: .userInitiated)
  private var ortEnv: ORTEnv?
  private var sessions: [String: ORTSession] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "medya_motoru/media", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(MedyaMotoruPlugin(), channel: channel)
  }

  // MARK: - yardımcılar

  private func url(_ v: Any?) -> URL { URL(fileURLWithPath: v as? String ?? "") }

  private func num(_ v: Any?, _ d: Int64) -> Int64 { (v as? NSNumber)?.int64Value ?? d }

  private func dbl(_ v: Any?, _ d: Double) -> Double { (v as? NSNumber)?.doubleValue ?? d }

  private func ms(_ v: Int64) -> CMTime { CMTime(value: v, timescale: 1000) }

  private func durationMs(_ asset: AVAsset) -> Int64 {
    let s = CMTimeGetSeconds(asset.duration)
    return s.isFinite ? Int64(s * 1000) : 0
  }

  private func export(
    _ asset: AVAsset, preset: String, out: URL, type: AVFileType, range: CMTimeRange? = nil,
    done: @escaping (Error?) -> Void
  ) {
    try? FileManager.default.removeItem(at: out)
    guard let s = AVAssetExportSession(asset: asset, presetName: preset) else {
      done(MedyaError("export"))
      return
    }
    s.outputURL = out
    s.outputFileType = type
    s.shouldOptimizeForNetworkUse = true
    s.audioTimePitchAlgorithm = .spectral
    if let r = range { s.timeRange = r }
    s.exportAsynchronously {
      if s.status == .completed { done(nil) } else { done(s.error ?? MedyaError("export")) }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let a = call.arguments as? [String: Any] ?? [:]
    let done: (Error?) -> Void = { e in
      DispatchQueue.main.async {
        if let e = e {
          result(FlutterError(code: "medya", message: e.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }
    }
    switch call.method {
    case "probe": probe(a, result)
    case "trim": trim(a, done)
    case "merge": merge(a, done)
    case "compress": compress(a, done)
    case "speed": speed(a, done)
    case "extractAudio", "encodeM4a":
      export(AVURLAsset(url: url(a["input"])), preset: AVAssetExportPresetAppleM4A, out: url(a["output"]), type: .m4a, done: done)
    case "decodeToWav": decodeToWav(a, done)
    case "frames": frames(a, result)
    case "slideshow": slideshow(a, done)
    case "onnxRun": onnxRun(a, result)
    case "saveRingtone", "openSoundSettings": result(false)
    default: result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - bilgi

  private func probe(_ a: [String: Any], _ result: @escaping FlutterResult) {
    let asset = AVURLAsset(url: url(a["path"]))
    let v = asset.tracks(withMediaType: .video).first
    var w = 0, h = 0, rot = 0
    if let t = v {
      let size = t.naturalSize.applying(t.preferredTransform)
      w = Int(abs(size.width))
      h = Int(abs(size.height))
      let tr = t.preferredTransform
      rot = Int((atan2(Double(tr.b), Double(tr.a)) * 180 / Double.pi).rounded())
    }
    let info: [String: Any] = [
      "durationMs": durationMs(asset),
      "width": w, "height": h, "rotation": rot,
      "hasAudio": !asset.tracks(withMediaType: .audio).isEmpty,
      "hasVideo": v != nil,
    ]
    result(info)
  }

  // MARK: - video

  private func trim(_ a: [String: Any], _ done: @escaping (Error?) -> Void) {
    let asset = AVURLAsset(url: url(a["input"]))
    let start = ms(num(a["startMs"], 0))
    let endMs = num(a["endMs"], -1)
    let end = endMs > 0 ? ms(endMs) : asset.duration
    export(asset, preset: AVAssetExportPresetHighestQuality, out: url(a["output"]), type: .mp4,
           range: CMTimeRange(start: start, end: end), done: done)
  }

  private func merge(_ a: [String: Any], _ done: @escaping (Error?) -> Void) {
    let paths = a["inputs"] as? [String] ?? []
    let comp = AVMutableComposition()
    guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
          let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      done(MedyaError("composition"))
      return
    }
    var cursor = CMTime.zero
    var first = true
    do {
      for p in paths {
        let asset = AVURLAsset(url: URL(fileURLWithPath: p))
        let range = CMTimeRange(start: .zero, duration: asset.duration)
        if let src = asset.tracks(withMediaType: .video).first {
          try vt.insertTimeRange(range, of: src, at: cursor)
          if first {
            vt.preferredTransform = src.preferredTransform
            first = false
          }
        }
        if let src = asset.tracks(withMediaType: .audio).first {
          try at.insertTimeRange(range, of: src, at: cursor)
        }
        cursor = CMTimeAdd(cursor, asset.duration)
      }
    } catch {
      done(error)
      return
    }
    export(comp, preset: AVAssetExportPresetHighestQuality, out: url(a["output"]), type: .mp4, done: done)
  }

  private func compress(_ a: [String: Any], _ done: @escaping (Error?) -> Void) {
    let h = num(a["maxHeight"], 720)
    let preset: String
    switch h {
    case ..<481: preset = AVAssetExportPreset640x480
    case ..<541: preset = AVAssetExportPreset960x540
    case ..<721: preset = AVAssetExportPreset1280x720
    default: preset = AVAssetExportPreset1920x1080
    }
    export(AVURLAsset(url: url(a["input"])), preset: preset, out: url(a["output"]), type: .mp4, done: done)
  }

  private func speed(_ a: [String: Any], _ done: @escaping (Error?) -> Void) {
    let asset = AVURLAsset(url: url(a["input"]))
    let factor = max(0.1, dbl(a["factor"], 1))
    let keepAudio = (a["keepAudio"] as? Bool ?? true)
    let comp = AVMutableComposition()
    let range = CMTimeRange(start: .zero, duration: asset.duration)
    do {
      if let src = asset.tracks(withMediaType: .video).first,
         let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try vt.insertTimeRange(range, of: src, at: .zero)
        vt.preferredTransform = src.preferredTransform
      }
      if keepAudio, let src = asset.tracks(withMediaType: .audio).first,
         let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        try at.insertTimeRange(range, of: src, at: .zero)
      }
    } catch {
      done(error)
      return
    }
    comp.scaleTimeRange(range, toDuration: CMTimeMultiplyByFloat64(asset.duration, multiplier: 1.0 / factor))
    export(comp, preset: AVAssetExportPresetHighestQuality, out: url(a["output"]), type: .mp4, done: done)
  }

  // MARK: - ONNX

  private func onnxRun(_ a: [String: Any], _ result: @escaping FlutterResult) {
    guard let model = a["model"] as? String,
          let input = a["input"] as? FlutterStandardTypedData,
          let dims = a["shape"] as? [Any] else {
      result(FlutterError(code: "onnx", message: "arguments", details: nil))
      return
    }
    let shape: [NSNumber] = dims.map { NSNumber(value: Int64("\($0)") ?? 1) }
    work.async {
      do {
        if self.ortEnv == nil { self.ortEnv = try ORTEnv(loggingLevel: ORTLoggingLevel.warning) }
        guard let env = self.ortEnv else { throw MedyaError("env") }
        let session: ORTSession
        if let s = self.sessions[model] {
          session = s
        } else {
          session = try ORTSession(env: env, modelPath: model, sessionOptions: nil)
          self.sessions[model] = session
        }
        guard let inName = try session.inputNames().first,
              let outName = try session.outputNames().first else { throw MedyaError("names") }
        let tensor = try ORTValue(
          tensorData: NSMutableData(data: input.data), elementType: ORTTensorElementDataType.float, shape: shape)
        let outs = try session.run(withInputs: [inName: tensor], outputNames: Set([outName]), runOptions: nil)
        guard let o = outs[outName] else { throw MedyaError("output") }
        let data = try o.tensorData() as Data
        DispatchQueue.main.async { result(FlutterStandardTypedData(float32: data)) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "onnx", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  // MARK: - ses

  private func decodeToWav(_ a: [String: Any], _ done: @escaping (Error?) -> Void) {
    let input = url(a["input"])
    let output = url(a["output"])
    let rate = Int(num(a["sampleRate"], 44100))
    let ch = Int(num(a["channels"], 1))
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw MedyaError("no audio") }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
          AVSampleRateKey: rate,
          AVNumberOfChannelsKey: ch,
        ]
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? MedyaError("reader") }
        var pcm = Data()
        while let sb = out.copyNextSampleBuffer() {
          if let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [UInt8](repeating: 0, count: len)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &chunk)
            pcm.append(contentsOf: chunk)
          }
        }
        if reader.status == .failed { throw reader.error ?? MedyaError("reader") }
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + pcm.count))
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(UInt16(ch)); u32(UInt32(rate)); u32(UInt32(rate * ch * 2)); u16(UInt16(ch * 2)); u16(16)
        wav.append(contentsOf: Array("data".utf8))
        u32(UInt32(pcm.count))
        wav.append(pcm)
        try? FileManager.default.removeItem(at: output)
        try wav.write(to: output)
        done(nil)
      } catch {
        done(error)
      }
    }
  }

  // MARK: - kareler ve slayt gösterisi

  private func frames(_ a: [String: Any], _ result: @escaping FlutterResult) {
    let input = url(a["input"])
    let dir = URL(fileURLWithPath: a["outDir"] as? String ?? NSTemporaryDirectory(), isDirectory: true)
    let count = max(1, Int(num(a["count"], 20)))
    let maxSide = CGFloat(num(a["maxSide"], 480))
    let startMs = num(a["startMs"], 0)
    let endMs = num(a["endMs"], -1)
    DispatchQueue.global(qos: .userInitiated).async {
      let asset = AVURLAsset(url: input)
      let gen = AVAssetImageGenerator(asset: asset)
      gen.appliesPreferredTrackTransform = true
      gen.maximumSize = CGSize(width: maxSide, height: maxSide)
      gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
      gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let durMs = self.durationMs(asset)
      let end = endMs > 0 ? min(endMs, durMs) : durMs
      let start = max(0, min(startMs, end))
      var paths: [String] = []
      for i in 0..<count {
        let t = start + (end - start) * Int64(i) / Int64(count)
        guard let cg = try? gen.copyCGImage(at: CMTime(value: t, timescale: 1000), actualTime: nil),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.88) else { continue }
        let f = dir.appendingPathComponent(String(format: "frame_%03d.jpg", i))
        if (try? data.write(to: f)) != nil { paths.append(f.path) }
      }
      DispatchQueue.main.async { result(paths) }
    }
  }

  private func pixelBuffer(_ img: CGImage, _ w: Int, _ h: Int) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs = [
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
    ] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32ARGB, attrs, &pb)
    guard let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let ctx = CGContext(
      data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
    ctx.setFillColor(UIColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let s = min(CGFloat(w) / CGFloat(img.width), CGFloat(h) / CGFloat(img.height))
    let dw = CGFloat(img.width) * s
    let dh = CGFloat(img.height) * s
    ctx.draw(img, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
    return buf
  }

  private func slideshow(_ a: [String: Any], _ done: @escaping (Error?) -> Void) {
    let paths = a["images"] as? [String] ?? []
    let step = num(a["msPerImage"], 2000)
    let w = Int(num(a["width"], 1280))
    let h = Int(num(a["height"], 720))
    let out = url(a["output"])
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
          kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MedyaError("writer") }
        writer.startSession(atSourceTime: .zero)
        var n: Int64 = 0
        for p in paths {
          guard let img = UIImage(contentsOfFile: p)?.cgImage, let buf = self.pixelBuffer(img, w, h) else { continue }
          while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
          if !adaptor.append(buf, withPresentationTime: CMTime(value: n * step, timescale: 1000)) {
            throw writer.error ?? MedyaError("append")
          }
          n += 1
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: max(1, n) * step, timescale: 1000))
        writer.finishWriting {
          done(writer.status == .completed ? nil : (writer.error ?? MedyaError("writer")))
        }
      } catch {
        done(error)
      }
    }
  }
}
