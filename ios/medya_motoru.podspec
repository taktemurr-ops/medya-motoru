#
# Medya motoru: iOS yerel ortam eklentisi (AVFoundation + Core ML).
# ONNX Runtime pod'u kullanılmaz: modeller Core ML (.mlmodel) olarak indirilir.
#
Pod::Spec.new do |s|
  s.name             = 'medya_motoru'
  s.version          = '1.0.0'
  s.summary          = 'Medya motoru: video kesme, birleştirme, sıkıştırma, hız, ses çıkarma, slayt gösterisi.'
  s.description      = 'AVFoundation ile cihaz üzerinde video ve ses işleme, Core ML ile model çalıştırma; ağ kullanmaz.'
  s.homepage         = 'https://github.com/taktemurr-ops/medya-motoru'
  s.license          = { :type => 'Proprietary', :text => 'Tüm hakları saklıdır.' }
  s.author           = { 'Game Studio 100' => 'taktemurr-ops' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'AVFoundation', 'CoreMedia', 'CoreVideo', 'CoreML'
  s.platform         = :ios, '15.6'
  s.swift_version    = '5.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
