/// Podcast / RSS oynatıcı: kullanıcının eklediği RSS/Atom akışları ve OPML
/// içe/dışa aktarma, çevrimdışı dinleme için indirme, kaldığı yerden sürdürme
/// ve oynatma hızı. Katalog ya da hazır akış yoktur; içerikler yayıncılarındır.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:studio_core/apps/apps.dart';

import '../common.dart';
import '../dsp/audio.dart' show fmtClock;
import '../ek4_core.dart';
import '../platform/files.dart';

class PodcastPlayerTool extends StatefulWidget {
  final ToolContext t;
  const PodcastPlayerTool(this.t, {super.key});

  @override
  State<PodcastPlayerTool> createState() => _PodcastPlayerState();
}

class _PodcastPlayerState extends State<PodcastPlayerTool> {
  ToolContext get t => widget.t;

  final List<PodcastFeed> _feeds = [];
  int _open = -1; // açık akış
  final Map<String, int> _posMs = {};
  final Set<String> _played = {};
  final Map<String, String> _dl = {};
  final Map<String, double> _dlProgress = {};
  double _speed = 1;
  bool _busy = false;

  AudioPlayer? _player;
  PodcastEpisode? _now;
  bool _playing = false;
  Duration _pos = Duration.zero, _dur = Duration.zero;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _rememberPosition();
    unawaited(_persistState());
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_player?.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await t.store.readList('feeds');
    final st = await t.store.readMap('pstate');
    if (!mounted) return;
    setState(() {
      for (final r in rows) {
        final url = r['url'], title = r['title'];
        if (url is! String || title is! String) continue;
        final eps = r['eps'];
        _feeds.add(PodcastFeed(
          url: url,
          title: title,
          author: r['author'] is String ? r['author'] as String : '',
          image: r['image'] is String ? r['image'] as String : '',
          episodes: [
            if (eps is List)
              for (final e in eps)
                if (PodcastEpisode.fromJson(e) case final ep?) ep,
          ],
        ));
      }
      final pos = st['pos'];
      if (pos is Map) {
        pos.forEach((k, v) {
          if (k is String && v is num) _posMs[k] = v.toInt();
        });
      }
      final pl = st['played'];
      if (pl is List) _played.addAll(pl.whereType<String>());
      final dl = st['dl'];
      if (dl is Map) {
        dl.forEach((k, v) {
          if (k is String && v is String) _dl[k] = v;
        });
      }
      final sp = st['speed'];
      if (sp is num && kPodcastSpeeds.contains(sp.toDouble())) _speed = sp.toDouble();
    });
    // Silinmiş indirmeleri temizle.
    for (final e in Map<String, String>.of(_dl).entries) {
      if (!await MediaFiles.exists(e.value)) _dl.remove(e.key);
    }
  }

  Future<void> _persistFeeds() => t.store.writeList('feeds', [
        for (final f in _feeds)
          {
            'url': f.url,
            'title': f.title,
            'author': f.author,
            'image': f.image,
            'eps': [for (final e in f.episodes.take(300)) e.toJson()],
          },
      ]);

  Future<void> _persistState() => t.store.writeMap('pstate', {
        'pos': _posMs,
        'played': _played.toList(),
        'dl': _dl,
        'speed': _speed,
      });

  // ------------------------------------------------------------ akışlar

  Future<PodcastFeed?> _fetch(String url) async {
    final body = await MediaFiles.getText(url);
    if (body == null) return null;
    return parseFeed(url, body);
  }

  Future<void> _addFeed(String url, {bool quiet = false}) async {
    url = url.trim();
    if (!isFeedUrl(url)) {
      if (!quiet) snack(context, L(t, 'pod_bad_feed'));
      return;
    }
    if (_feeds.any((f) => f.url == url)) return;
    setState(() => _busy = true);
    final f = await _fetch(url);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (f != null) _feeds.add(f);
    });
    if (f == null) {
      if (!quiet) snack(context, L(t, 'pod_bad_feed'));
      return;
    }
    await _persistFeeds();
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    for (var i = 0; i < _feeds.length; i++) {
      final f = await _fetch(_feeds[i].url);
      if (f != null && mounted) setState(() => _feeds[i] = f);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _persistFeeds();
  }

  Future<void> _askUrl() async {
    final c = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(L(t, 'pod_add')),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(labelText: L(t, 'pod_url'), hintText: 'https://'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.core('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(t.core('ok'))),
        ],
      ),
    );
    c.dispose();
    if (url != null && mounted) await _addFeed(url);
  }

  Future<void> _importOpml() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
      final b = r?.files.firstOrNull?.bytes;
      if (b == null) return;
      final list = parseOpml(utf8.decode(b, allowMalformed: true));
      if (list.isEmpty) {
        if (mounted) snack(context, L(t, 'pod_bad_feed'));
        return;
      }
      for (final (_, url) in list) {
        if (!mounted) return;
        await _addFeed(url, quiet: true);
      }
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
  }

  Future<void> _exportOpml() async {
    final xml = buildOpml([for (final f in _feeds) (f.title, f.url)]);
    await saveText(context, t, xml, 'podcasts.opml', 'text/x-opml');
  }

  Future<void> _removeFeed(int i) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(L(t, 'delete_item_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.core('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(L(t, 'delete'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final f = _feeds[i];
    for (final e in f.episodes) {
      final p = _dl.remove(e.guid);
      if (p != null) unawaited(MediaFiles.delete(p));
    }
    setState(() {
      _feeds.removeAt(i);
      _open = -1;
    });
    await _persistFeeds();
    await _persistState();
  }

  // ------------------------------------------------------------ indirme

  Future<void> _download(PodcastEpisode e) async {
    final dir = await MediaFiles.appDir('podcasts');
    if (dir == null) return;
    final path = '$dir/${episodeFileName(e.url)}';
    setState(() => _dlProgress[e.guid] = 0);
    try {
      await for (final p in MediaFiles.download(e.url, path)) {
        if (mounted) setState(() => _dlProgress[e.guid] = p);
      }
      _dl[e.guid] = path;
      await _persistState();
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
    if (mounted) setState(() => _dlProgress.remove(e.guid));
  }

  Future<void> _deleteDownload(PodcastEpisode e) async {
    final p = _dl.remove(e.guid);
    if (p != null) await MediaFiles.delete(p);
    if (mounted) setState(() {});
    await _persistState();
  }

  // ------------------------------------------------------------ oynatma

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final p = AudioPlayer();
    _subs.add(p.onPositionChanged.listen((d) {
      if (mounted) setState(() => _pos = d);
    }));
    _subs.add(p.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    }));
    _subs.add(p.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() => _playing = s == PlayerState.playing);
      if (s != PlayerState.playing) {
        _rememberPosition();
        unawaited(_persistState());
      }
    }));
    _subs.add(p.onPlayerComplete.listen((_) {
      final e = _now;
      if (e == null) return;
      setState(() {
        _played.add(e.guid);
        _posMs.remove(e.guid);
      });
      unawaited(_persistState());
    }));
    _player = p;
    _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_playing) {
        _rememberPosition();
        unawaited(_persistState());
      }
    });
    return p;
  }

  void _rememberPosition() {
    final e = _now;
    if (e == null || _pos <= Duration.zero) return;
    final total = _dur.inMilliseconds;
    if (total > 0 && total - _pos.inMilliseconds < 30000) {
      _played.add(e.guid);
      _posMs.remove(e.guid);
    } else {
      _posMs[e.guid] = _pos.inMilliseconds;
    }
  }

  Future<void> _play(PodcastEpisode e) async {
    _rememberPosition();
    final p = _ensurePlayer();
    setState(() {
      _now = e;
      _pos = Duration.zero;
      _dur = Duration(seconds: e.seconds);
    });
    try {
      await p.stop();
      final local = _dl[e.guid];
      final Source src = local != null ? DeviceFileSource(local) : UrlSource(e.url);
      final at = Duration(milliseconds: _posMs[e.guid] ?? 0);
      await p.play(src, position: at > Duration.zero ? at : null);
      await p.setPlaybackRate(_speed);
    } catch (_) {
      if (mounted) snack(context, L(t, 'failed'));
    }
  }

  Future<void> _skip(int seconds) async {
    final p = _player;
    if (p == null) return;
    final target = _pos + Duration(seconds: seconds);
    final max = _dur > Duration.zero ? _dur : target;
    await p.seek(target < Duration.zero ? Duration.zero : (target > max ? max : target));
  }

  Future<void> _setSpeed(double v) async {
    setState(() => _speed = v);
    await _player?.setPlaybackRate(v);
    await _persistState();
  }

  // ------------------------------------------------------------ arayüz

  Widget _playerBar() {
    final e = _now;
    if (e == null) return const SizedBox.shrink();
    return AppPanel(
      child: Column(children: [
        Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        Slider(
          value: _pos.inMilliseconds.clamp(0, math.max<int>(1, _dur.inMilliseconds)).toDouble(),
          max: math.max<int>(1, _dur.inMilliseconds).toDouble(),
          onChanged: (v) => unawaited(_player?.seek(Duration(milliseconds: v.round()))),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(fmtClock(_pos.inMilliseconds / 1000), style: const TextStyle(color: Colors.white70)),
          Text(fmtClock(_dur.inMilliseconds / 1000), style: const TextStyle(color: Colors.white70)),
        ]),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: L(t, 'pod_back'), iconSize: 34, onPressed: () => _skip(-15), icon: const Icon(Icons.replay_10_rounded)),
            IconButton.filled(
              iconSize: 44,
              onPressed: () {
                final p = _ensurePlayer();
                unawaited(_playing ? p.pause() : p.resume());
              },
              icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            ),
            IconButton(tooltip: L(t, 'pod_fwd'), iconSize: 34, onPressed: () => _skip(30), icon: const Icon(Icons.forward_30_rounded)),
          ]),
        ),
        ChipsRow<double>(
          values: kPodcastSpeeds,
          label: (v) => '${v == v.roundToDouble() ? v.toInt() : v}×',
          selected: _speed,
          onChanged: (v) => unawaited(_setSpeed(v)),
        ),
      ]),
    );
  }

  Widget _episodeTile(PodcastEpisode e) {
    final s = AppLook.of(context);
    final progress = _dlProgress[e.guid];
    final local = _dl.containsKey(e.guid);
    final played = _played.contains(e.guid);
    final resume = _posMs[e.guid];
    final sub = [
      if (e.published != null) e.published!.toLocal().toIso8601String().substring(0, 10),
      if (e.seconds > 0) fmtClock(e.seconds.toDouble()),
      if (resume != null) '▶ ${fmtClock(resume / 1000)}',
      if (played) L(t, 'pod_played'),
      if (local) L(t, 'pod_downloaded'),
    ].join(' · ');
    return ListTile(
      leading: Icon(_now?.guid == e.guid ? Icons.graphic_eq_rounded : (played ? Icons.check_circle_rounded : Icons.podcasts_rounded),
          color: _now?.guid == e.guid ? s.accent : (played ? Colors.white38 : null)),
      title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: played ? Colors.white60 : null)),
      subtitle: Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => unawaited(_play(e)),
      trailing: !MediaFiles.hasFileSystem
          ? null
          : progress != null
              ? SizedBox(width: 28, height: 28, child: CircularProgressIndicator(value: progress > 0 ? progress : null, strokeWidth: 3))
              : local
                  ? IconButton(tooltip: L(t, 'pod_remove_dl'), icon: const Icon(Icons.download_done_rounded), onPressed: () => _deleteDownload(e))
                  : IconButton(tooltip: L(t, 'pod_download'), icon: const Icon(Icons.download_rounded), onPressed: () => _download(e)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = _open >= 0 && _open < _feeds.length ? _feeds[_open] : null;
    return ToolList(children: [
      _playerBar(),
      if (_busy) BusyLine(L(t, 'processing')),
      if (open == null) ...[
        AppHeading(L(t, 'pod_subs'), icon: Icons.rss_feed_rounded),
        if (_feeds.isEmpty) AppInfoCard(L(t, 'pod_empty'), icon: Icons.podcasts_rounded),
        for (var i = 0; i < _feeds.length; i++)
          ListTile(
            leading: const Icon(Icons.rss_feed_rounded),
            title: Text(_feeds[i].title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [if (_feeds[i].author.isNotEmpty) _feeds[i].author, '${_feeds[i].episodes.length}'].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => setState(() => _open = i),
            trailing: IconButton(tooltip: L(t, 'delete'), icon: const Icon(Icons.delete_outline_rounded), onPressed: () => _removeFeed(i)),
          ),
        ActionRow([
          AppButton(label: L(t, 'pod_add'), icon: Icons.add_link_rounded, onPressed: _busy ? null : _askUrl),
          if (_feeds.isNotEmpty) AppButton(label: L(t, 'pod_refresh'), icon: Icons.refresh_rounded, onPressed: _busy ? null : _refresh),
        ]),
        ActionRow([
          AppButton(label: L(t, 'pod_import'), icon: Icons.file_open_rounded, onPressed: _busy ? null : _importOpml),
          if (_feeds.isNotEmpty) AppButton(label: L(t, 'pod_export'), icon: Icons.ios_share_rounded, onPressed: _exportOpml),
        ]),
      ] else ...[
        ListTile(
          leading: IconButton(icon: const BackButtonIcon(), onPressed: () => setState(() => _open = -1)),
          title: Text(open.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: open.author.isEmpty ? null : Text(open.author, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (open.episodes.isEmpty) AppInfoCard(L(t, 'empty_list'), icon: Icons.podcasts_rounded),
        for (final e in open.episodes.take(200)) _episodeTile(e),
      ],
      AppInfoCard(L(t, 'pod_no_catalog'), icon: Icons.info_outline_rounded),
      if (kIsWeb) AppInfoCard(L(t, 'pod_web_note'), icon: Icons.public_rounded),
    ]);
  }
}
