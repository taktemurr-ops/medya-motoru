"""Real-ESRGAN general-x4v3 (BSD-3-Clause) PyTorch ağırlığını ONNX'e çevirir.

Kaynak (resmî sürüm): https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth
Kullanım: pip install torch onnx && python tool/convert_models.py realesr-general-x4v3.pth assets/models/realesr_general_x4v3.onnx

Renklendirme modeli (deneysel, isteğe bağlı indirme) için de aynı yol:
richzhang/colorization ECCV16 (BSD-2-Clause) ağırlığı
https://colorizers.s3.us-east-2.amazonaws.com/colorization_release_v1-9b330a0b.pth
`--eccv16` ile ONNX'e çevrilir; çıktı depoda tutulmaz, sürüm eki olarak
yayınlanır (bkz. README, "Modeller").

iOS (Core ML): ONNX Runtime yerine Core ML kullanılır. Aynı resmî kaynaklardan
`coremltools` ile tek dosyalık `.mlmodel` (NeuralNetwork, iOS 14+) üretilir;
girdi/çıktı tensörleri ONNX sürümüyle birebir aynıdır (Dart ön/son işleme
ortaktır). Cihaz modeli ilk kullanımda indirip `MLModel.compileModel` ile derler.
  --coreml-u2netp  u2netp.onnx       u2netp.mlmodel        (rembg yansıması, ONNX → PyTorch → Core ML)
  --coreml-esrgan  realesr.pth       realesr.mlmodel       (esnek boyut 1..512)
  --coreml-eccv16  eccv16.pth        colorization.mlmodel
"""
import sys

import torch
import torch.nn as nn
import torch.nn.functional as F


class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode='nearest')


class ECCVGenerator(nn.Module):
    """Zhang ve ark. 2016 (ECCV16) renklendirme ağı: girdi L (1×1×256×256),
    çıktı ab (1×2×256×256), -1..1 değil, gerçek ab ölçeğinde (×110 uygulanmış)."""

    def __init__(self):
        super().__init__()
        BN = nn.BatchNorm2d

        def blk(cin, cout, n, stride_last=1, dil=1, bn=True):
            layers = []
            for i in range(n):
                s = stride_last if i == n - 1 else 1
                layers += [nn.Conv2d(cin if i == 0 else cout, cout, 3, s, dil, dilation=dil, bias=True), nn.ReLU(True)]
            if bn:
                layers.append(BN(cout))
            return nn.Sequential(*layers)

        self.model1 = blk(1, 64, 2, 2)
        self.model2 = blk(64, 128, 2, 2)
        self.model3 = blk(128, 256, 3, 2)
        self.model4 = blk(256, 512, 3)
        self.model5 = blk(512, 512, 3, dil=2)
        self.model6 = blk(512, 512, 3, dil=2)
        self.model7 = blk(512, 512, 3)
        self.model8 = nn.Sequential(
            nn.ConvTranspose2d(512, 256, 4, 2, 1, bias=True), nn.ReLU(True),
            nn.Conv2d(256, 256, 3, 1, 1, bias=True), nn.ReLU(True),
            nn.Conv2d(256, 256, 3, 1, 1, bias=True), nn.ReLU(True),
            nn.Conv2d(256, 313, 1, 1, 0, bias=True))
        self.softmax = nn.Softmax(dim=1)
        self.model_out = nn.Conv2d(313, 2, 1, 1, 0, dilation=1, bias=False)
        self.upsample4 = nn.Upsample(scale_factor=4, mode='bilinear')

    def forward(self, l):
        x = (l - 50.0) / 100.0
        for m in [self.model1, self.model2, self.model3, self.model4, self.model5, self.model6, self.model7, self.model8]:
            x = m(x)
        return self.upsample4(self.model_out(self.softmax(x))) * 110.0


def esrgan(src, dst):
    net = SRVGGNetCompact()
    sd = torch.load(src, map_location='cpu')
    net.load_state_dict(sd.get('params', sd), strict=True)
    net.eval()
    x = torch.rand(1, 3, 64, 64)
    torch.onnx.export(net, x, dst, input_names=['input'], output_names=['output'], opset_version=17,
                      dynamic_axes={'input': {2: 'h', 3: 'w'}, 'output': {2: 'h4', 3: 'w4'}}, dynamo=False)


def eccv16(src, dst):
    net = ECCVGenerator()
    sd = torch.load(src, map_location='cpu')
    net.load_state_dict(sd, strict=True)
    net.eval()
    x = torch.rand(1, 1, 256, 256) * 100
    torch.onnx.export(net, x, dst, input_names=['l'], output_names=['ab'], opset_version=17, dynamo=False)


def _coreml(net, example, inputs, dst):
    import coremltools as ct
    net.eval()
    with torch.no_grad():
        traced = torch.jit.trace(net, example)
    ml = ct.convert(traced, inputs=inputs, outputs=[ct.TensorType(name='output')],
                    convert_to='neuralnetwork', minimum_deployment_target=ct.target.iOS14)
    ml.short_description = 'medya-motoru'
    ml.save(dst)
    return traced


class _First(nn.Module):
    """U²-Netp yedi çıktı verir; uygulama yalnız ilkini (d0) kullanır."""

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        o = self.net(x)
        return o[0] if isinstance(o, (list, tuple)) else o


def coreml_u2netp(src, dst):
    import coremltools as ct
    import onnx
    import onnxruntime as ort
    from onnx2torch import convert
    m = onnx.load(src)
    first = m.graph.output[0].name
    net = _First(convert(m)).eval()
    x = torch.rand(1, 3, 320, 320)
    with torch.no_grad():
        y = net(x).numpy()
    ref = ort.InferenceSession(src).run([first], {m.graph.input[0].name: x.numpy()})[0]
    err = float(abs(y - ref).max())
    assert err < 1e-3, err
    print('u2netp torch~onnx', err)
    _coreml(net, x, [ct.TensorType(name='input', shape=(1, 3, 320, 320))], dst)


def coreml_esrgan(src, dst):
    import coremltools as ct
    net = SRVGGNetCompact()
    sd = torch.load(src, map_location='cpu')
    net.load_state_dict(sd.get('params', sd), strict=True)
    h, w = ct.RangeDim(1, 512, 64), ct.RangeDim(1, 512, 64)
    _coreml(net, torch.rand(1, 3, 64, 64), [ct.TensorType(name='input', shape=(1, 3, h, w))], dst)


def coreml_eccv16(src, dst):
    import coremltools as ct
    net = ECCVGenerator()
    net.load_state_dict(torch.load(src, map_location='cpu'), strict=True)
    _coreml(net, torch.rand(1, 1, 256, 256) * 100, [ct.TensorType(name='input', shape=(1, 1, 256, 256))], dst)


if __name__ == '__main__':
    cmd = {'--eccv16': eccv16, '--coreml-u2netp': coreml_u2netp, '--coreml-esrgan': coreml_esrgan,
           '--coreml-eccv16': coreml_eccv16}
    if sys.argv[1] in cmd:
        cmd[sys.argv[1]](sys.argv[2], sys.argv[3])
    else:
        esrgan(sys.argv[1], sys.argv[2])
