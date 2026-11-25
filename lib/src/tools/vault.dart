/// Gizli fotoğraf albümü: fotoğraf ve videolar cihazda, parolayla şifreli
/// bir kasada saklanır (PBKDF2-HMAC-SHA256 ile türetilen anahtar, AES-256-GCM;
/// bkz. media_core.dart). Dosya adları da şifreli dizinde durur. Uygulama arka
/// plana geçince kasa kilitlenir; art arda yanlış parolada bekleme süresi
/// artar. Parola unutulursa içerik kurtarılamaz (arka kapı yoktur). Hiçbir şey
/// internete gönderilmez. Web'de dosya sistemi olmadığından yoktur.
///
/// İsteğe bağlı biyometrik açma (local_auth): veri anahtarı, platformun güvenli
/// deposunda (Android Keystore / iOS Anahtar Zinciri, yalnız bu cihaz) tutulan
/// rastgele bir sırla sarılır (bio.bin). Parola asıl anahtar olarak kalır;
/// biyometrik açma yalnız bir kısayoldur ve kapatılınca sır ile sarılı anahtar
/// silinir.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../media_core.dart';
import '../native.dart';
import '../platform/files.dart';
import 'video.dart' show VideoPreview;

/// En büyük video (bellekte şifrelendiği için).
const int kVaultMaxBytes = 150 * 1024 * 1024;

Future<Uint8List> _sealJob((Uint8List, Uint8List) a) => sealBytes(a.$1, a.$2);
Future<Uint8List?> _openJob((Uint8List, Uint8List) a) => openBytes(a.$1, a.$2);
Future<Uint8List?> _unlockJob((String, String) a) async {
  final h = VaultHeader.fromJson(a.$1);
  return h == null ? null : unlockVault(h, a.$2);
}

Future<(String, Uint8List)> _createJob(String password) async {
  final (h, k) = await createVault(password);
  return (h.toJson(), k);
}

Future<String?> _rewrapJob((String, Uint8List, String) a) async {
  final h = VaultHeader.fromJson(a.$1);
  return h == null ? null : (await rewrapVault(h, a.$2, a.$3)).toJson();
}

enum _Stage { loading, unsupported, create, locked, open }

class VaultTool extends StatefulWidget {
  final ToolContext t;
  const VaultTool(this.t, {super.key});
  @override
  State<VaultTool> createState() => _VaultState();
}

class _VaultState extends State<VaultTool> with WidgetsBindingObserver {
  ToolContext get t => widget.t;
  _Stage _stage = _Stage.loading;
  String? _dir;
  String? _header;
  Uint8List? _key;
  List<VaultItem> _items = [];
  final Map<String, Uint8List> _thumbs = {};
  final ValueNotifier<int> _lockGen = ValueNotifier<int>(0);
  final TextEditingController _p1 = TextEditingController();
  final TextEditingController _p2 = TextEditingController();
  bool _busy = false;
  String? _msg;
  int _fails = 0;
  DateTime? _waitUntil;
  Timer? _waitTimer;

  // Biyometrik açma.
  static const String _bioSecretKey = 'medya_gizli_album_bio_v1';
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device),
  );
  final LocalAuthentication _auth = LocalAuthentication();
  bool _bioAvailable = false;
  bool _bioOn = false;
  bool _authBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _waitTimer?.cancel();
    _p1.dispose();
    _p2.dispose();
    _lockGen.dispose();
    super.dispose();
  }

  /// Uygulama arka plana geçince kasayı kilitler.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Biyometrik pencere açıkken bazı cihazlar uygulamayı duraklatır; kilitleme.
    if (_authBusy) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) _lock();
  }

  String _f(String name) => '$_dir/$name';

  Future<void> _init() async {
    if (kIsWeb || !MediaFiles.hasFileSystem) {
      setState(() => _stage = _Stage.unsupported);
      return;
    }
    final d = await MediaFiles.appDir('gizli_album');
    if (d == null) {
      setState(() => _stage = _Stage.unsupported);
      return;
    }
    _dir = d;
    final h = await MediaFiles.read(_f('header.json'));
    _fails = await t.store.readInt('fails');
    final until = await t.store.readInt('wait_until');
    if (until > DateTime.now().millisecondsSinceEpoch) _waitUntil = DateTime.fromMillisecondsSinceEpoch(until);
    _bioOn = await t.store.readBool('bio');
    try {
      _bioAvailable = await _auth.isDeviceSupported() && await _auth.canCheckBiometrics;
    } catch (_) {
      _bioAvailable = false;
    }
    if (!mounted) return;
    setState(() {
      _header = h == null ? null : utf8.decode(h);
      _stage = _header == null || VaultHeader.fromJson(_header!) == null ? _Stage.create : _Stage.locked;
    });
    _startWaitTimer();
    if (_stage == _Stage.locked && _bioOn && _bioAvailable) unawaited(_unlockBio());
  }

  // ------------------------------------------------------------ biyometrik

  Future<bool> _bioAuth() async {
    _authBusy = true;
    try {
      return await _auth.authenticate(localizedReason: L(t, 'bio_reason'), biometricOnly: true);
    } catch (_) {
      return false;
    } finally {
      _authBusy = false;
    }
  }

  /// Biyometrik doğrulamadan sonra sarılı anahtarı güvenli depodaki sırla açar.
  Future<void> _unlockBio() async {
    final header = _header == null ? null : VaultHeader.fromJson(_header!);
    if (header == null || _busy || _stage != _Stage.locked) return;
    if (!await _bioAuth() || !mounted) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    Uint8List? key;
    try {
      final secret = await _secure.read(key: _bioSecretKey);
      final wrapped = await MediaFiles.read(_f('bio.bin'));
      if (secret != null && wrapped != null) key = await unwrapBioKey(header, base64Decode(secret), wrapped);
    } catch (_) {
      key = null;
    }
    if (!mounted) return;
    if (key == null) {
      // Sır kaybolduysa ya da bozulduysa biyometrik açma kapatılır; parola geçerli.
      await _bioDisable();
      if (mounted) {
        setState(() {
          _busy = false;
          _msg = L(t, 'bio_failed');
        });
      }
      return;
    }
    _fails = 0;
    await t.store.write('fails', '0');
    _waitUntil = null;
    await t.store.write('wait_until', '0');
    _key = key;
    _p1.clear();
    await _loadIndex();
    if (mounted) {
      setState(() {
        _busy = false;
        _stage = _Stage.open;
      });
    }
  }

  Future<void> _bioDisable() async {
    try {
      await _secure.delete(key: _bioSecretKey);
    } catch (_) {}
    if (_dir != null) await MediaFiles.delete(_f('bio.bin'));
    await t.store.writeBool('bio', false);
    _bioOn = false;
  }

  Future<void> _setBio(bool on) async {
    if (!on) {
      await _bioDisable();
      if (mounted) setState(() {});
      return;
    }
    if (_key == null) return;
    if (!await _bioAuth()) {
      if (mounted) snack(context, L(t, 'bio_failed'));
      return;
    }
    final key = _key;
    if (key == null || !mounted) return;
    var ok = false;
    try {
      final secret = newBioSecret();
      final wrapped = await wrapBioKey(secret, key);
      if (await MediaFiles.write(_f('bio.bin'), wrapped)) {
        await _secure.write(key: _bioSecretKey, value: base64Encode(secret));
        await t.store.writeBool('bio', true);
        _bioOn = true;
        ok = true;
      }
    } catch (_) {
      ok = false;
    }
    if (!ok) await _bioDisable();
    if (!mounted) return;
    setState(() {});
    snack(context, ok ? L(t, 'bio_enabled') : L(t, 'failed'));
  }

  void _startWaitTimer() {
    _waitTimer?.cancel();
    if (_waitUntil == null) return;
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (tm) {
      if (!mounted) return;
      if (DateTime.now().isAfter(_waitUntil!)) {
        tm.cancel();
        setState(() => _waitUntil = null);
      } else {
        setState(() {});
      }
    });
  }

  void _lock() {
    if (_stage != _Stage.open) return;
    _key = null;
    _thumbs.clear();
    _items = [];
    _lockGen.value++;
    _p1.clear();
    _p2.clear();
    if (mounted) setState(() => _stage = _Stage.locked);
  }

  Future<void> _create() async {
    final a = _p1.text, b = _p2.text;
    if (!passwordOk(a) || a != b) {
      setState(() => _msg = L(t, passwordOk(a) ? 'pass_mismatch' : 'pass_short'));
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    final (header, key) = await compute(_createJob, a);
    final ok = await MediaFiles.write(_f('header.json'), Uint8List.fromList(utf8.encode(header)));
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _busy = false;
        _msg = L(t, 'failed');
      });
      return;
    }
    _header = header;
    _key = key;
    _items = [];
    await _saveIndex();
    _p1.clear();
    _p2.clear();
    setState(() {
      _busy = false;
      _stage = _Stage.open;
    });
  }

  Future<void> _unlock() async {
    if (_waitUntil != null || _header == null) return;
    setState(() {
      _busy = true;
      _msg = null;
    });
    final key = await compute(_unlockJob, (_header!, _p1.text));
    if (!mounted) return;
    if (key == null) {
      _fails++;
      await t.store.write('fails', '$_fails');
      final w = lockoutFor(_fails);
      if (w > Duration.zero) {
        _waitUntil = DateTime.now().add(w);
        await t.store.write('wait_until', '${_waitUntil!.millisecondsSinceEpoch}');
        _startWaitTimer();
      }
      setState(() {
        _busy = false;
        _msg = L(t, 'wrong_password');
      });
      return;
    }
    _fails = 0;
    await t.store.write('fails', '0');
    _key = key;
    _p1.clear();
    await _loadIndex();
    if (mounted) {
      setState(() {
        _busy = false;
        _stage = _Stage.open;
      });
    }
  }

  Future<void> _loadIndex() async {
    final raw = await MediaFiles.read(_f('index.bin'));
    final clear = raw == null || _key == null ? null : await compute(_openJob, (_key!, raw));
    _items = clear == null ? [] : decodeIndex(utf8.decode(clear));
    for (final it in _items) {
      final th = await MediaFiles.read(_f('${it.id}.thm'));
      if (th == null || _key == null) continue;
      final c = await compute(_openJob, (_key!, th));
      if (c != null) _thumbs[it.id] = c;
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveIndex() async {
    final key = _key;
    if (key == null) return;
    final sealed = await compute(_sealJob, (key, Uint8List.fromList(utf8.encode(encodeIndex(_items)))));
    await MediaFiles.write(_f('index.bin'), sealed);
  }

  /// Dosyayı şifreleyip kasaya ekler.
  Future<bool> _addBytes(String name, Uint8List bytes, Uint8List? thumb, {bool video = false}) async {
    final key = _key;
    if (key == null) return false;
    final id = newItemId();
    final body = await compute(_sealJob, (key, bytes));
    if (!await MediaFiles.write(_f('$id.bin'), body)) return false;
    if (thumb != null) {
      final th = await compute(_sealJob, (key, thumb));
      await MediaFiles.write(_f('$id.thm'), th);
      _thumbs[id] = thumb;
    }
    _items.insert(0, VaultItem(id, name, video, bytes.length, DateTime.now().millisecondsSinceEpoch));
    await _saveIndex();
    return true;
  }

  Future<Uint8List?> _thumbOfImage(Uint8List bytes) async {
    final im = await decodeUi(bytes, maxSide: 320);
    if (im == null) return null;
    final png = await pngOf(im);
    im.dispose();
    return png;
  }

  Future<void> _addPhotos() async {
    final picks = await MediaPick.images();
    if (picks.isEmpty) return;
    setState(() => _busy = true);
    var n = 0;
    for (final p in picks) {
      final b = await p.read();
      if (b == null) continue;
      if (await _addBytes(p.name, b, await _thumbOfImage(b))) n++;
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    setState(() => _busy = false);
    snack(context, L(t, 'vault_added', {'n': n}));
  }

  Future<void> _addVideo() async {
    final path = await MediaPick.video();
    if (path == null) return;
    if (await MediaFiles.size(path) > kVaultMaxBytes) {
      if (mounted) snack(context, L(t, 'too_large'));
      return;
    }
    setState(() => _busy = true);
    Uint8List? thumb;
    final tmp = await MediaFiles.appDir('gizli_album_tmp');
    if (tmp != null) {
      final frames = await MedyaNative.frames(path, tmp, count: 1, maxSide: 320);
      if (frames.isNotEmpty) {
        thumb = await MediaFiles.read(frames.first);
        for (final f in frames) {
          await MediaFiles.delete(f);
        }
      }
    }
    final bytes = await MediaFiles.read(path);
    var ok = false;
    if (bytes != null) ok = await _addBytes(path.split('/').last, bytes, thumb, video: true);
    if (!mounted) return;
    setState(() => _busy = false);
    snack(context, ok ? L(t, 'vault_added', {'n': 1}) : L(t, 'failed'));
  }

  Future<void> _delete(VaultItem it) async {
    await MediaFiles.delete(_f('${it.id}.bin'));
    await MediaFiles.delete(_f('${it.id}.thm'));
    _items.removeWhere((x) => x.id == it.id);
    _thumbs.remove(it.id);
    await _saveIndex();
    if (mounted) setState(() {});
  }

  Future<Uint8List?> _open(VaultItem it) async {
    final key = _key;
    final raw = await MediaFiles.read(_f('${it.id}.bin'));
    if (key == null || raw == null) return null;
    return compute(_openJob, (key, raw));
  }

  Future<bool> _confirm(String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          content: Text(text),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.core('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.core('ok'))),
          ],
        ),
      ) ==
      true;

  Future<void> _changePassword() async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L(t, 'change_password')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: a, obscureText: true, decoration: InputDecoration(labelText: L(t, 'new_password'))),
          TextField(controller: b, obscureText: true, decoration: InputDecoration(labelText: L(t, 'repeat_password'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.core('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(t.core('ok'))),
        ],
      ),
    );
    final p1 = a.text, p2 = b.text;
    a.dispose();
    b.dispose();
    if (ok != true || !mounted) return;
    if (!passwordOk(p1) || p1 != p2) {
      snack(context, L(t, passwordOk(p1) ? 'pass_mismatch' : 'pass_short'));
      return;
    }
    setState(() => _busy = true);
    final nh = await compute(_rewrapJob, (_header!, _key!, p1));
    if (nh != null && await MediaFiles.write(_f('header.json'), Uint8List.fromList(utf8.encode(nh)))) _header = nh;
    if (!mounted) return;
    setState(() => _busy = false);
    snack(context, nh == null ? L(t, 'failed') : L(t, 'saved'));
  }

  Future<void> _wipe() async {
    if (!await _confirm(L(t, 'delete_vault_confirm'))) return;
    for (final it in List<VaultItem>.of(_items)) {
      await MediaFiles.delete(_f('${it.id}.bin'));
      await MediaFiles.delete(_f('${it.id}.thm'));
    }
    await MediaFiles.delete(_f('index.bin'));
    await MediaFiles.delete(_f('header.json'));
    await _bioDisable();
    await t.store.write('fails', '0');
    _key = null;
    _header = null;
    _items = [];
    _thumbs.clear();
    _lockGen.value++;
    if (mounted) setState(() => _stage = _Stage.create);
  }

  Widget _passField(TextEditingController c, String label, {VoidCallback? onSubmit}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: TextField(
          controller: c,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          onSubmitted: onSubmit == null ? null : (_) => onSubmit(),
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.key_rounded)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    switch (_stage) {
      case _Stage.loading:
        return const Center(child: CircularProgressIndicator());
      case _Stage.unsupported:
        return ToolList(children: [notAvailable(t)]);
      case _Stage.create:
        return ToolList(children: [
          AppHeading(L(t, 'vault_create'), icon: Icons.enhanced_encryption_rounded),
          _passField(_p1, L(t, 'new_password')),
          _passField(_p2, L(t, 'repeat_password'), onSubmit: _create),
          if (_msg != null) Padding(padding: const EdgeInsets.all(8), child: Text(_msg!, style: const TextStyle(color: Colors.orangeAccent))),
          if (_busy) BusyLine(L(t, 'processing')) else AppButton(label: L(t, 'vault_create'), icon: Icons.lock_rounded, onPressed: _create),
          AppInfoCard(L(t, 'vault_warning'), icon: Icons.warning_amber_rounded),
          AppInfoCard(L(t, 'vault_note'), icon: Icons.privacy_tip_outlined),
        ]);
      case _Stage.locked:
        final wait = _waitUntil?.difference(DateTime.now());
        return ToolList(children: [
          const SizedBox(height: 24),
          const Icon(Icons.lock_rounded, size: 72),
          _passField(_p1, L(t, 'password'), onSubmit: _unlock),
          if (_msg != null) Padding(padding: const EdgeInsets.all(8), child: Text(_msg!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent))),
          if (wait != null && !wait.isNegative)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(L(t, 'wait_s', {'s': wait.inSeconds + 1}), textAlign: TextAlign.center),
            ),
          if (_busy)
            BusyLine(L(t, 'processing'))
          else
            AppButton(label: L(t, 'unlock'), icon: Icons.lock_open_rounded, onPressed: _waitUntil == null ? _unlock : null),
          if (!_busy && _bioOn && _bioAvailable)
            Center(
              child: OutlinedButton.icon(
                onPressed: _unlockBio,
                icon: const Icon(Icons.fingerprint_rounded),
                label: Text(L(t, 'bio_unlock')),
              ),
            ),
          Center(child: TextButton(onPressed: _wipe, child: Text(L(t, 'delete_vault')))),
        ]);
      case _Stage.open:
        return ToolList(children: [
          ActionRow([
            FilledButton.icon(onPressed: _busy ? null : _addPhotos, icon: const Icon(Icons.add_photo_alternate_rounded), label: Text(L(t, 'pick_photos'))),
            if (MedyaNative.supported)
              OutlinedButton.icon(onPressed: _busy ? null : _addVideo, icon: const Icon(Icons.video_call_rounded), label: Text(L(t, 'pick_video'))),
            OutlinedButton.icon(onPressed: _lock, icon: const Icon(Icons.lock_rounded), label: Text(L(t, 'lock'))),
            PopupMenuButton<int>(
              onSelected: (i) => switch (i) {
                0 => _changePassword(),
                2 => _setBio(!_bioOn),
                _ => _wipe(),
              },
              itemBuilder: (_) => [
                PopupMenuItem(value: 0, child: Text(L(t, 'change_password'))),
                if (_bioAvailable) CheckedPopupMenuItem(value: 2, checked: _bioOn, child: Text(L(t, 'bio_unlock'))),
                PopupMenuItem(value: 1, child: Text(L(t, 'delete_vault'))),
              ],
            ),
          ]),
          if (_busy) BusyLine(L(t, 'processing')),
          if (_items.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(L(t, 'empty_list'), textAlign: TextAlign.center))
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                children: [
                  for (var i = 0; i < _items.length; i++)
                    InkWell(
                      onTap: () => _view(i),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(fit: StackFit.expand, children: [
                          if (_thumbs[_items[i].id] != null)
                            Image.memory(_thumbs[_items[i].id]!, fit: BoxFit.cover, gaplessPlayback: true)
                          else
                            Container(color: Colors.white10, child: const Icon(Icons.image_rounded)),
                          if (_items[i].video)
                            const Align(alignment: Alignment.center, child: Icon(Icons.play_circle_fill_rounded, size: 36, color: Colors.white70)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          AppInfoCard(L(t, 'originals_note'), icon: Icons.info_outline_rounded),
          if (_bioOn) AppInfoCard(L(t, 'bio_note'), icon: Icons.fingerprint_rounded),
        ]);
    }
  }

  Future<void> _view(int index) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _VaultViewer(
        t: t,
        items: _items,
        start: index,
        lockGen: _lockGen,
        open: _open,
        onDelete: (it) async {
          if (!await _confirm(L(t, 'delete_item_confirm'))) return false;
          await _delete(it);
          return true;
        },
      ),
    ));
    if (mounted) setState(() {});
  }
}

class _VaultViewer extends StatefulWidget {
  final ToolContext t;
  final List<VaultItem> items;
  final int start;
  final ValueNotifier<int> lockGen;
  final Future<Uint8List?> Function(VaultItem) open;
  final Future<bool> Function(VaultItem) onDelete;
  const _VaultViewer({
    required this.t,
    required this.items,
    required this.start,
    required this.lockGen,
    required this.open,
    required this.onDelete,
  });
  @override
  State<_VaultViewer> createState() => _VaultViewerState();
}

class _VaultViewerState extends State<_VaultViewer> {
  ToolContext get t => widget.t;
  late final PageController _pc = PageController(initialPage: widget.start);
  late int _i = widget.start;
  final Map<String, Uint8List> _cache = {};
  final Map<String, String> _videoFiles = {};
  late final int _gen;

  @override
  void initState() {
    super.initState();
    _gen = widget.lockGen.value;
    widget.lockGen.addListener(_onLock);
    _ensure(_i);
  }

  @override
  void dispose() {
    widget.lockGen.removeListener(_onLock);
    _pc.dispose();
    for (final p in _videoFiles.values) {
      unawaited(MediaFiles.delete(p));
    }
    _cache.clear();
    super.dispose();
  }

  void _onLock() {
    if (widget.lockGen.value != _gen && mounted) Navigator.of(context).pop();
  }

  Future<void> _ensure(int i) async {
    if (i < 0 || i >= widget.items.length) return;
    final it = widget.items[i];
    if (_cache.containsKey(it.id)) return;
    final b = await widget.open(it);
    if (b == null || !mounted) return;
    _cache[it.id] = b;
    if (it.video) {
      final ext = it.name.contains('.') ? it.name.split('.').last : 'mp4';
      final p = await MediaFiles.writeTemp(b, ext);
      if (p != null) _videoFiles[it.id] = p;
    }
    if (mounted) setState(() {});
  }

  VaultItem get _item => widget.items[_i];

  Future<void> _export() async {
    final b = _cache[_item.id];
    if (b == null) return;
    bool ok;
    if (_item.video) {
      final p = _videoFiles[_item.id];
      ok = p != null && await MediaFiles.saveVideo(p, _item.name);
    } else {
      ok = await MediaFiles.saveImage(b, _item.name);
    }
    if (mounted) snack(context, ok ? L(t, 'saved') : L(t, 'failed'));
  }

  Future<void> _share() async {
    final b = _cache[_item.id];
    if (b == null) return;
    await MediaFiles.shareBytes(b, _item.name, _item.video ? 'video/*' : 'image/*');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const Scaffold();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${_i + 1} / ${widget.items.length}'),
        actions: [
          IconButton(tooltip: L(t, 'save'), icon: const Icon(Icons.download_rounded), onPressed: _export),
          IconButton(tooltip: L(t, 'share'), icon: const Icon(Icons.share_rounded), onPressed: _share),
          IconButton(
            tooltip: L(t, 'delete'),
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              final it = _item;
              if (await widget.onDelete(it) && mounted) {
                final p = _videoFiles.remove(it.id);
                if (p != null) unawaited(MediaFiles.delete(p));
                if (widget.items.isEmpty) {
                  Navigator.of(context).pop();
                } else {
                  setState(() => _i = _i.clamp(0, widget.items.length - 1));
                  _ensure(_i);
                }
              }
            },
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pc,
        itemCount: widget.items.length,
        onPageChanged: (i) {
          setState(() => _i = i);
          _ensure(i);
          _ensure(i + 1);
        },
        itemBuilder: (context, i) {
          final it = widget.items[i];
          final b = _cache[it.id];
          if (b == null) return const Center(child: CircularProgressIndicator());
          if (it.video) {
            final p = _videoFiles[it.id];
            return Center(child: p == null ? Text(L(t, 'failed')) : VideoPreview(p));
          }
          return InteractiveViewer(maxScale: 6, child: Center(child: Image.memory(b, gaplessPlayback: true)));
        },
      ),
    );
  }
}
