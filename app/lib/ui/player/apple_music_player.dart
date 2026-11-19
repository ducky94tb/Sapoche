import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../player_sheet.dart';
import '../widgets/artwork.dart';
import '../widgets/playback_bar.dart';
import '../widgets/volume_bar.dart';
import 'classic_player.dart';
import 'lyrics_ticker.dart';
import 'parts.dart';

/// The player of the style of the full cover: the cover runs across the whole width at the top and melts into the
/// colours behind it, the buttons are plain glyphs with no disc, and the row of icons has the lyrics, where the sound
/// goes and the queue (the comments and the sleep timer are in the "…" of the song). With a picture to show, a panel
/// open, on a screen on its side and in a roomy window the places are the classic player's, with this style's look.
class AppleMusicPlayer extends StatelessWidget {
  const AppleMusicPlayer({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
    required this.onChoose,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;
  final ValueChanged<NowPlayingPanel> onChoose;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => box.maxWidth > box.maxHeight
        ? ClassicPlayer(
            controller: controller,
            current: current,
            panel: panel,
            onPanel: onPanel,
            onChoose: onChoose,
          )
        : _tall(context),
  );

  Widget _tall(BuildContext context) {
    final p = context.palette;
    final inset = MediaQuery.paddingOf(context).top;
    // The cover runs up under the status bar; with a picture to show or a panel open the way out is the grabber, as in
    // the classic player
    final bleed = panel == NowPlayingPanel.cover && !controller.snapshot.video;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerColumnMax * 1.5),
        child: Column(
          children: [
            if (!bleed) ...[
              SizedBox(height: inset),
              // The way out in the middle and the button for Audio or Video on the right
              SizedBox(
                height: 44,
                width: double.infinity,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PlayerGrabber(color: p.textTertiary.withValues(alpha: 0.5)),
                    Positioned(
                      right: 12,
                      child: ModeToggle(controller: controller),
                    ),
                  ],
                ),
              ),
            ],
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                layoutBuilder: (current, previous) => Stack(
                  fit: StackFit.expand,
                  children: [...previous, ?current],
                ),
                child: switch (panel) {
                  // A picture keeps its own frame, with margins, as in the classic player
                  NowPlayingPanel.cover when controller.snapshot.video =>
                    PlayerCoverStage(
                      key: const ValueKey('cover'),
                      controller: controller,
                      current: current,
                      margin: _margin,
                    ),
                  NowPlayingPanel.cover => _FullCover(
                    key: const ValueKey('cover'),
                    controller: controller,
                    current: current,
                  ),
                  _ => PlayerPanelStage(
                    key: ValueKey(panel),
                    controller: controller,
                    current: current,
                    panel: panel,
                    onCover: () => onChoose(NowPlayingPanel.cover),
                  ),
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _margin),
              child: Column(
                children: [
                  const SizedBox(height: 4),
                  // The lines of the lyrics, running, above the seek bar
                  if (panel == NowPlayingPanel.cover &&
                      !controller.snapshot.video)
                    LyricsTicker(controller: controller, track: current),
                  const SizedBox(height: 6),
                  PlaybackBar(
                    controller: controller,
                    middle: controller.snapshot.video
                        ? null
                        : _Quality(quality: controller.audioQuality),
                  ),
                  const SizedBox(height: 6),
                  TransportRow(controller: controller),
                  const SizedBox(height: 6),
                  if (!kIsWeb && panel == NowPlayingPanel.cover)
                    VolumeBar(controller: controller),
                  const SizedBox(height: 4),
                  PlayerToolbar(
                    controller: controller,
                    panel: panel,
                    onPanel: onPanel,
                  ),
                  DeviceLine(controller: controller),
                  if (controller.snapshot.inRoom) ...[
                    const SizedBox(height: 6),
                    RoomStrip(controller: controller),
                  ],
                  const SizedBox(height: playerBottomGap),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The space at each side of the bars, the buttons and the song.
const _margin = 22.0;

/// The cover across the whole width and as tall as the place gives it, its foot melting into what is behind; the song
/// stands over that foot, so that nothing is left empty between the cover and the seek bar.
class _FullCover extends StatefulWidget {
  const _FullCover({
    super.key,
    required this.controller,
    required this.current,
  });

  final RoomController controller;
  final QueueEntry current;

  @override
  State<_FullCover> createState() => _FullCoverState();
}

class _FullCoverState extends State<_FullCover> {
  PlayerSheetController? _sheet;

  RoomController get controller => widget.controller;
  QueueEntry get current => widget.current;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The cover melts into what is behind it, so it does not fly: while the page is pulled down it is this cover that
    // moves, with its melting foot, not a plain square (`PlayerSheetController.coverFlies`)
    _sheet = PlayerSheetScope.of(context)..coverFlies = false;
  }

  @override
  void dispose() {
    _sheet?.coverFlies = true;
    super.dispose();
  }

  /// How far below the status bar the blur fades out.
  static const _blurFade = 40.0;

  /// The mask of the blur: full at the top, then easing off to nothing (a smooth step, in nine stops).
  static const _ease = [
    Color(0xFF000000),
    Color(0xF7000000),
    Color(0xE0000000),
    Color(0xB8000000),
    Color(0x80000000),
    Color(0x48000000),
    Color(0x1F000000),
    Color(0x07000000),
    Color(0x00000000),
  ];

  /// How far the song stands over the foot of the cover.
  static const _overlap = 56.0;

  /// About the height of the title, the artist and the star, and the gap above them (more with larger text).
  static double _titleHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(64.0) + 12;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return LayoutBuilder(
      builder: (context, box) {
        // The picture fills the width and what height there is, cropped to it; not taller than 1.4 of its width, where
        // the screen is much taller than it is wide
        final height = min(
          box.maxWidth * 1.4,
          max(0.0, box.maxHeight - _titleHeight(context) + _overlap),
        );
        return SizedBox(
          height: box.maxHeight,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: height,
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xFF000000),
                      Color(0xFF000000),
                      Color(0x00000000),
                    ],
                    stops: [0, 0.45, 0.9],
                  ).createShader(rect),
                  child: CoverSlot(
                    controller: sheet,
                    child: Artwork(
                      key: sheet.pageCover,
                      url: current.thumb,
                      size: height,
                      width: box.maxWidth,
                      radius: 0,
                      sharp: true,
                      crossfade: true,
                    ),
                  ),
                ),
              ),
              // Under the status bar the picture is blurred and a little darkened, so that the time and the notices on it
              // are not lost in the picture. The blur is a blurred copy of the cover laid over the sharp one, and it is
              // let through by a mask that thins out by an easing curve, so that the sharp picture comes up out of the
              // blur with no line where it begins
              if (top > 0) ...[
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: top + _blurFade,
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: _ease,
                    ).createShader(rect),
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: Alignment.topCenter,
                        minHeight: height,
                        maxHeight: height,
                        child: ImageFiltered(
                          imageFilter: ui.ImageFilter.blur(
                            sigmaX: 12,
                            sigmaY: 12,
                            tileMode: TileMode.clamp,
                          ),
                          child: Artwork(
                            url: current.thumb,
                            size: height,
                            width: box.maxWidth,
                            radius: 0,
                            sharp: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // A little dark that thins out the same way
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: top + _blurFade,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x73000000),
                          Color(0x5C000000),
                          Color(0x3A000000),
                          Color(0x1C000000),
                          Color(0x08000000),
                          Color(0x00000000),
                        ],
                        stops: [0, 0.2, 0.45, 0.7, 0.88, 1],
                      ),
                    ),
                  ),
                ),
              ],
              // Audio or Video, on the picture, under the status bar
              Positioned(
                top: top + 4,
                right: 12,
                child: ModeToggle(controller: controller, onPicture: true),
              ),
              // The way out, on the picture
              Positioned(
                top: top + 6,
                left: 0,
                right: 0,
                child: const Center(
                  child: PlayerGrabber(color: Color(0xB3FFFFFF)),
                ),
              ),
              Positioned(
                left: _margin,
                right: _margin,
                top: max(0.0, height - _overlap),
                child: PlayerTitleRow(controller: controller, current: current),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The quality the songs are fetched in, in the line between the two times: its name and the rate it comes to.
class _Quality extends StatelessWidget {
  const _Quality({required this.quality});

  final AudioQuality quality;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = switch (quality) {
      AudioQuality.low => '${S.audioQualityLow} · ${S.audioQualityLowRate}',
      AudioQuality.normal =>
        '${S.audioQualityNormal} · ${S.audioQualityNormalRate}',
      AudioQuality.high => '${S.audioQualityHigh} · ${S.audioQualityHighRate}',
      AudioQuality.max => '${S.audioQualityMax} · ${S.audioQualityMaxRate}',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.graphic_eq_rounded, size: 14, color: p.textSecondary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: p.textSecondary),
          ),
        ),
      ],
    );
  }
}
