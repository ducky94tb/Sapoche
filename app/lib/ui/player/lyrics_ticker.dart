import 'dart:math';

import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import '../widgets/low_rate_timer.dart';
import 'look.dart';
import 'parts.dart';
import '../widgets/motion.dart';

/// One small line of the lyrics on the face of the player: the line being sung, moving on as the song does. A line that is
/// longer than the place runs sideways, in the time of the line, until all of it has been shown (never cut with dots). Three dots stand for a rest between lines and for the lyrics still on
/// their way. A touch opens the page of the lyrics. Lyrics with no times have nothing to run, and a song with none has
/// no lines: the place is then not taken.
class LyricsTicker extends StatefulWidget {
  const LyricsTicker({
    super.key,
    required this.controller,
    required this.track,
    this.height = 28,
  });

  final RoomController controller;
  final QueueEntry track;

  /// The height of the line, which the place keeps while there are lines to show.
  final double height;

  @override
  State<LyricsTicker> createState() => _LyricsTickerState();
}

class _LyricsTickerState extends State<LyricsTicker> {
  /// A line lights up a little before it is sung, as in the page of the lyrics.
  static const _leadMs = 250;

  Future<Lyrics?>? _lyrics;
  String? _for;
  int? _active;
  bool _playing = false;

  late final LowRateTimer _ticker = LowRateTimer(
    const Duration(milliseconds: 200),
    _update,
  );

  RoomController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.player.addListener(_sync);
    _c.addListener(_sync);
    _ticker.run(_c.player.value.playing);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_lyrics == null) _load();
  }

  @override
  void didUpdateWidget(LyricsTicker old) {
    super.didUpdateWidget(old);
    if (widget.track.videoId != _for) _load();
  }

  @override
  void dispose() {
    _c.player.removeListener(_sync);
    _c.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  void _load() {
    _for = widget.track.videoId;
    _active = null;
    _lyrics = widget.track.isLocal
        ? Future.value(null)
        : AppScope.of(context).music
              .lyrics(widget.track)
              .catchError((Object _) => null);
  }

  void _sync() {
    _ticker.run(_c.player.value.playing);
    // A line that runs sideways stops with the song
    if (_playing != _c.isPlaying && mounted) {
      setState(() => _playing = _c.isPlaying);
    }
    _update();
  }

  Lyrics? _known;

  void _update() {
    final lyrics = _known;
    if (!mounted || lyrics == null) return;
    final line = lyrics.lineAt(_c.positionMs() + _leadMs);
    if (line != _active) setState(() => _active = line);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Lyrics?>(
    key: ValueKey(_for),
    future: _lyrics,
    builder: (context, snapshot) {
      final done = snapshot.connectionState == ConnectionState.done;
      final lyrics = snapshot.data;
      _known = lyrics;
      // Nothing to run: the place is not taken
      final show = !done || (lyrics?.synced ?? false);
      final active = done && lyrics != null
          ? lyrics.lineAt(_c.positionMs() + _leadMs)
          : null;
      return MotionSize(
        milliseconds: 200,
        alignment: Alignment.topCenter,
        child: show
            // A line that runs sideways repaints every frame: in a layer of its own, so that the cover and the colours
            // behind (a mask, a blur) are not drawn again with it
            ? RepaintBoundary(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      PlayerLookScope.panelOf(context)
                          ?.call(NowPlayingPanel.lyrics),
                  child: Semantics(
                    button: true,
                    label: S.lyrics,
                    excludeSemantics: true,
                    child: SizedBox(
                      height: widget.height,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _Lines(
                          lines: done ? lyrics!.lines : const [],
                          active: active,
                          positionMs: _c.positionMs(),
                          playing: _c.isPlaying,
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : const SizedBox(width: double.infinity),
      );
    },
  );
}

/// The line being sung; the dots where there is no line (before the first, in a rest, while waiting).
class _Lines extends StatelessWidget {
  const _Lines({
    required this.lines,
    required this.active,
    required this.positionMs,
    required this.playing,
  });

  final List<LyricLine> lines;
  final int? active;
  final int positionMs;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final now = active == null || lines.isEmpty ? '' : lines[active!].text;
    // How long the line lasts: until the next one begins, or a while for the last
    var duration = 6000;
    if (active != null && active! + 1 < lines.length) {
      duration = lines[active! + 1].ms - lines[active!].ms;
    }
    final elapsed = active == null || lines.isEmpty
        ? 0
        : positionMs - lines[active!].ms;
    return AnimatedSwitcher(
      duration: Motion.of(context, 250),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.centerLeft,
        children: [...previous, ?current],
      ),
      child: KeyedSubtree(
        key: ValueKey(active),
        child: now.isEmpty
            ? const _Dots()
            : _RunningLine(
                text: now,
                style: theme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: p.text,
                ),
                durationMs: duration,
                elapsedMs: elapsed,
                playing: playing,
              ),
      ),
    );
  }
}

/// A line of text on one line. When it is wider than its place it stands still first, so that its first words can be
/// read, then runs sideways at an easy pace, then stands again with its end in view. The pace is the pace of reading, not
/// the one that the time of the line forces: a short line that is long to the eye still gets the hold at its start, and
/// runs as slowly as the time it has allows.
class _RunningLine extends StatefulWidget {
  const _RunningLine({
    required this.text,
    required this.style,
    required this.durationMs,
    required this.elapsedMs,
    required this.playing,
  });

  final String text;
  final TextStyle? style;

  /// How long the line is sung for, and how far into it the song is when it appears.
  final int durationMs;
  final int elapsedMs;
  final bool playing;

  @override
  State<_RunningLine> createState() => _RunningLineState();
}

class _RunningLineState extends State<_RunningLine>
    with SingleTickerProviderStateMixin {
  /// The part of the line's time it stands at the start, before it runs: at least this long (a line is read from its
  /// first word), at most this much of the line.
  static const _holdMinMs = 900;
  static const _holdMaxMs = 1600;
  static const _holdShare = 0.28;

  /// The part of the line's time by which the run is over: the rest, the end stands in view.
  static const _endShare = 0.9;

  /// The slowest it runs, in dp a second: a line sung over a long time does not crawl.
  static const _slowestPace = 28.0;

  /// The least a run takes, however short the line.
  static const _leastRunMs = 1800;

  /// The clock of the line is the song's time, not an animation: it must not be sped up (to twenty times, by the
  /// default) for someone who has asked the phone for less motion, which would make the line run past in a moment.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
    duration: Duration(milliseconds: widget.durationMs.clamp(1500, 90000)),
  );

  @override
  void initState() {
    super.initState();
    _clock.value = (widget.elapsedMs / _clock.duration!.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    if (widget.playing) _clock.forward();
  }

  @override
  void didUpdateWidget(_RunningLine old) {
    super.didUpdateWidget(old);
    if (widget.playing && !_clock.isAnimating && _clock.value < 1) {
      _clock.forward();
    }
    if (!widget.playing && _clock.isAnimating) _clock.stop();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  /// How far along the run it is, 0 to 1, [ms] into the line, for a line that has [more] dp that do not fit.
  double _progress(double ms, double more) {
    final total = _clock.duration!.inMilliseconds.toDouble();
    final hold = (total * _holdShare).clamp(
      _holdMinMs.toDouble(),
      _holdMaxMs.toDouble(),
    );
    final room = total * _endShare - hold;
    // At the pace of reading, or the whole of the room there is if that is less
    final run = min(
      room,
      max(_leastRunMs.toDouble(), more / _slowestPace * 1000),
    );
    if (run <= 0) return ms >= total ? 1 : 0;
    return Curves.easeInOut.transform(((ms - hold) / run).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: widget.style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      final text = Text(
        widget.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.visible,
        style: widget.style,
      );
      final more = width - box.maxWidth;
      // Fits: it stands still. The whole of it is in view, with nothing to run
      if (more <= 0) return text;
      return ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: 0,
          maxWidth: double.infinity,
          child: AnimatedBuilder(
            animation: _clock,
            builder: (context, child) => Transform.translate(
              offset: Offset(
                -more *
                    _progress(
                      _clock.value * _clock.duration!.inMilliseconds,
                      more,
                    ),
                0,
              ),
              child: child,
            ),
            child: text,
          ),
        ),
      );
    },
  );
}

class _Dots extends StatelessWidget {
  const _Dots();

  @override
  Widget build(BuildContext context) {
    final color = context.palette.textSecondary;
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
        ],
      ),
    );
  }
}
