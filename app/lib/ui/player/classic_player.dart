import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';
import 'comments_view.dart';
import 'lyrics_view.dart';
import 'up_next_view.dart';
import '../widgets/artwork.dart';
import '../widgets/edge_fade.dart';
import '../widgets/like_button.dart';
import '../widgets/marquee_text.dart';
import '../widgets/playback_bar.dart';
import '../widgets/volume_bar.dart';
import 'look.dart';
import 'parts.dart';

/// Side of the full player's cover. It depends only on the screen, so the cover can be decoded
/// at this size before the player is ever opened.
double coverSize(MediaQueryData media, {double margin = playerMargin}) {
  // Everything except the cover needs about this much height (the seek bar, the buttons, the volume, the icons); the
  // cover takes what is left. Its side margins are the ones of Apple Music, 32 on each side
  final otherContent = 460.0 * playerScale(media);
  return [
    min(media.size.width, playerColumnMax) - 2 * margin,
    media.size.height - media.padding.vertical - otherContent,
  ].reduce((a, b) => a < b ? a : b).clamp(140.0, playerColumnMax - 2 * margin);
}

/// The side margin of the full player: the cover, the title, the seek bar and the buttons all start and end on it.
const playerMargin = 32.0;

/// How wide the upright player's column gets. On a tablet it does not stretch across the screen: a cover that is a
/// third of the screen is out of proportion with buttons the size of a phone's.
const playerColumnMax = 560.0;

/// What is left under the last row of buttons, on top of the system's own bar: the icons do not sit on the edge.
const playerBottomGap = 28.0;

/// The player as Sapoche has always drawn it: the cover in the middle of an upright column, beside the controls on a
/// screen on its side, beside the queue in a roomy window.
class ClassicPlayer extends StatelessWidget {
  const ClassicPlayer({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
    required this.onChoose,
  });

  final RoomController controller;
  final QueueEntry current;

  /// What the middle of the player shows.
  final NowPlayingPanel panel;

  /// A touch on the button of a panel: a second touch on the open one goes back to the cover.
  final ValueChanged<NowPlayingPanel> onPanel;

  /// Shows that panel, whatever is open.
  final ValueChanged<NowPlayingPanel> onChoose;

  RoomController get _c => controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) =>
        box.maxWidth > box.maxHeight ? _wide(box) : _tall(context),
  );

  Widget _tall(BuildContext context) {
    final p = context.palette;

    // On a tablet held upright the column does not stretch across the screen
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: playerColumnMax),
        child: _tallColumn(p, current),
      ),
    );
  }

  Widget _tallColumn(Palette p, QueueEntry current) {
    return Column(
      children: [
        const SizedBox(height: 6),
        PlayerGrabber(color: p.textTertiary.withValues(alpha: 0.5)),
        const SizedBox(height: 10),
        ModePill(controller: _c),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: switch (panel) {
              NowPlayingPanel.cover => PlayerCoverStage(
                key: const ValueKey('cover'),
                controller: _c,
                current: current,
              ),
              _ => PlayerPanelStage(
                key: ValueKey(panel),
                controller: _c,
                current: current,
                panel: panel,
                onCover: () => onChoose(NowPlayingPanel.cover),
              ),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: playerMargin),
          child: Column(
            children: [
              const SizedBox(height: 14),
              PlaybackBar(controller: _c),
              const SizedBox(height: 14),
              TransportRow(controller: _c),
              const SizedBox(height: 6),
              // A browser has no volume of its own to set: the tab follows the computer's
              // Not while the lyrics or the queue are open: the queue gets the room (it shows a row more); the bar is
              // there again with the cover
              if (!kIsWeb && panel == NowPlayingPanel.cover)
                VolumeBar(controller: _c),
              const SizedBox(height: 4),
              PlayerToolbar(controller: _c, panel: panel, onPanel: onPanel),
              if (_c.snapshot.inRoom) ...[
                const SizedBox(height: 6),
                RoomStrip(controller: _c),
              ],
              const SizedBox(height: playerBottomGap),
            ],
          ),
        ),
      ],
    );
  }

  /// A window with room in it (a browser), laid out as YouTube Music and Apple Music do on a computer: the picture, as
  /// large as the place allows, with the song under it on the left, the queue or the lyrics beside it over the whole
  /// height on the right, and the controls in one strip along the bottom, as wide as the window. Both halves are always
  /// there, so nothing is left hanging at the sides, and the picture of any shape has the song under it to fill the
  /// place above and below.
  Widget _roomy(BoxConstraints box) {
    final video = _c.snapshot.video;
    // The queue is what shows beside the picture until the lyrics or the comments are asked for
    final panel =
        this.panel == NowPlayingPanel.lyrics ||
            this.panel == NowPlayingPanel.comments
        ? this.panel
        : NowPlayingPanel.upNext;
    const margin = 32.0;
    const gap = 32.0;
    // The song under the picture: its title and the strip of the room
    final caption = 16.0 + 64.0 + (_c.snapshot.inRoom ? 44.0 : 0.0);
    // The picture's half, as the layout below measures it, so that Audio or Video can stand over the picture
    final content = min(box.maxWidth, _roomyWidthMax);
    final left = (content - 2 * margin - gap) * (video ? 0.58 : 0.5);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _roomyWidthMax),
        child: Column(
          children: [
            // The way out on the edge, and Audio or Video over the picture it is about
            SizedBox(
              height: 48,
              child: Stack(
                children: [
                  const Positioned(
                    left: 16,
                    top: 0,
                    child: PlayerCloseButton(),
                  ),
                  Positioned(
                    left: margin,
                    width: left,
                    top: 0,
                    child: Center(child: ModePill(controller: _c)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(margin, 8, margin, 8),
                child: LayoutBuilder(
                  builder: (context, area) {
                    // A picture that is wide gets the larger half; a square one needs less than the height gives it
                    final left = (area.maxWidth - gap) * (video ? 0.58 : 0.5);
                    final room = max(120.0, area.maxHeight - caption);
                    final picture = video
                        ? min(left, room * 16 / 9)
                        : min(left, room);
                    return Row(
                      children: [
                        SizedBox(
                          width: left,
                          child: Center(
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // A picture taller than wide (a phone's video) shrinks to the height there is
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: picture,
                                      maxHeight: room,
                                    ),
                                    child: PlayerCoverArt(
                                      controller: _c,
                                      current: current,
                                      size: picture,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  SizedBox(
                                    width: picture,
                                    child: PlayerTitleRow(
                                      controller: _c,
                                      current: current,
                                    ),
                                  ),
                                  if (_c.snapshot.inRoom) ...[
                                    const SizedBox(height: 4),
                                    SizedBox(
                                      width: picture,
                                      child: RoomStrip(controller: _c),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: gap),
                        Expanded(
                          child: switch (panel) {
                            NowPlayingPanel.lyrics => LyricsView(
                              controller: _c,
                              track: current,
                            ),
                            NowPlayingPanel.comments => CommentsView(
                              controller: _c,
                              track: current,
                            ),
                            _ => UpNextView(controller: _c),
                          },
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            // The controls, in one strip: the panels and more on the left, the buttons over the seek bar in the middle,
            // the volume on the right (not in a browser). The seek bar is as wide as the buttons need it, not as the window
            Padding(
              padding: const EdgeInsets.fromLTRB(margin, 0, margin, 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        width: 280,
                        child: PlayerToolbar(
                          controller: _c,
                          panel: panel,
                          // One of the two is always showing beside the picture, so these are a choice between two and
                          // not switches: touching the lit one leaves it lit
                          onPanel: onChoose,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 520,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TransportRow(controller: _c, playSize: 56),
                        const SizedBox(height: 6),
                        PlaybackBar(controller: _c, compact: true),
                      ],
                    ),
                  ),
                  Expanded(
                    child: kIsWeb
                        ? const SizedBox.shrink()
                        : Align(
                            alignment: Alignment.centerRight,
                            child: SizedBox(
                              width: 240,
                              child: VolumeBar(controller: _c),
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The cover on the left, as tall as the screen allows; the controls, or a panel in their place, on the right. The
  /// title and the row of icons stay where they are when a panel opens: only what is between them changes.
  Widget _wide(BoxConstraints box) {
    if (box.maxHeight >= _roomyHeight && box.maxWidth >= _roomyWidth) {
      return _roomy(box);
    }
    const margin = 16.0;
    // As tall as the screen allows, but not the size of a wall on a big one
    final side = (box.maxHeight - 2 * margin).clamp(
      100.0,
      (box.maxWidth * 0.46).clamp(100.0, 480.0),
    );
    // A picture keeps its own proportions, so it gets a wider place than a square cover
    final left = _c.snapshot.video
        ? (side * 16 / 9).clamp(0.0, box.maxWidth * 0.52)
        : side;
    // The cover and the controls stay together in the middle of a wide window instead of drifting to its two sides
    final gutter = ((box.maxWidth - 1040) / 2).clamp(0.0, double.infinity);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24 + gutter, vertical: margin),
      child: Row(
        children: [
          SizedBox(
            width: left,
            height: box.maxHeight - 2 * margin,
            child: Center(
              child: PlayerCoverArt(
                controller: _c,
                current: current,
                size: side,
              ),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: _WideSide(
              controller: _c,
              current: current,
              panel: panel,
              onPanel: onPanel,
            ),
          ),
        ],
      ),
    );
  }
}

/// A wide window at least this tall and this wide has room for the picture, the queue and the controls at once: a
/// browser, a tablet on its side, a television (a 1080p one is about 960 by 540 dp), not a phone on its side.
const _roomyHeight = 500.0;
const _roomyWidth = 800.0;

/// The roomy layout does not stretch further than this: on a very wide window it stays in the middle.
const _roomyWidthMax = 1600.0;

/// The right side of the player on its side. From top to bottom: the way out and Audio or Video, the song, then what
/// the player shows in the middle (the controls, lyrics or the queue), the row of icons, the room. Everything but the
/// middle keeps its place when a panel opens, as in Apple Music.
class _WideSide extends StatelessWidget {
  const _WideSide({
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final ValueChanged<NowPlayingPanel> onPanel;

  /// About the least height the column needs; a place shorter than this scales it down rather than overflow.
  static const _leastHeight = 380.0;

  /// The title, the controls and the icons keep 20 from the side, where the lines of the queue start.
  static Widget inset(Widget child) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final scale = playerScale(MediaQuery.of(context));
    return LayoutBuilder(
      builder: (context, box) => FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          // Never narrower than the row of icons needs, so that a narrow place scales it down instead
          width: box.maxWidth.clamp(340.0, 480.0 * scale),
          height: max(box.maxHeight, _leastHeight),
          child: Column(
            children: [
              inset(
                Row(
                  children: [
                    const PlayerCloseButton(),
                    Expanded(
                      child: Center(child: ModePill(controller: controller)),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              inset(PlayerTitleRow(controller: controller, current: current)),
              const SizedBox(height: 4),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  // The queue has the 20 of its own at each side; lyrics get as much
                  child: switch (panel) {
                    NowPlayingPanel.cover => inset(
                      _WideControls(
                        key: const ValueKey('controls'),
                        controller: controller,
                      ),
                    ),
                    NowPlayingPanel.lyrics => Padding(
                      key: ValueKey(panel),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: LyricsView(controller: controller, track: current),
                    ),
                    NowPlayingPanel.comments => Padding(
                      key: ValueKey(panel),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: CommentsView(
                        controller: controller,
                        track: current,
                      ),
                    ),
                    NowPlayingPanel.upNext => UpNextView(
                      key: ValueKey(panel),
                      controller: controller,
                    ),
                  },
                ),
              ),
              inset(
                PlayerToolbar(
                  controller: controller,
                  panel: panel,
                  onPanel: onPanel,
                ),
              ),
              if (controller.snapshot.inRoom) ...[
                const SizedBox(height: 4),
                inset(RoomStrip(controller: controller)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// What the middle of the player on its side shows over the cover: the seek bar, the buttons and the volume.
class _WideControls extends StatelessWidget {
  const _WideControls({super.key, required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
    children: [
      PlaybackBar(controller: controller),
      TransportRow(controller: controller, playSize: 64),
      if (!kIsWeb) VolumeBar(controller: controller),
    ],
  );
}

/// The big cover (or the picture) with the title and the buttons that go with the song. The other styles of the upright
/// player use it too.
class PlayerCoverStage extends StatelessWidget {
  const PlayerCoverStage({
    super.key,
    required this.controller,
    required this.current,
    this.margin = playerMargin,
    this.showMore = true,
    this.gap = _coverGap,
    this.bottom = 16,
    this.between,
    this.betweenGap = 0,
    this.lowered = false,
  });

  final RoomController controller;
  final QueueEntry current;

  /// The space at each side of the cover and of the song under it.
  final double margin;

  /// Whether the "…" of the song stands in the title's row.
  final bool showMore;

  /// The space between the cover and the title, and what is kept free under the title.
  final double gap;
  final double bottom;

  /// Something between the cover and the title (the running lines of the lyrics). Its height is in [bottom].
  final Widget? between;

  /// The space between [between] and the title under it. It is in [bottom] too.
  final double betweenGap;

  /// The block of the cover and the song stands at the foot of its place, next to the seek bar, and what room there is
  /// over is above the cover, not round it.
  final bool lowered;

  @override
  Widget build(BuildContext context) {
    final artSize = coverSize(MediaQuery.of(context), margin: margin);
    if (controller.snapshot.video) {
      // The picture takes all the height there is and keeps its own shape in it: a wide one is as wide as the
      // column, an upright one as tall as the place, never over the title and the controls
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: margin),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                key: const ValueKey('video-place'),
                padding: const EdgeInsets.only(top: 12, bottom: 16),
                child: PlayerCoverArt(
                  controller: controller,
                  current: current,
                  size: artSize,
                ),
              ),
            ),
            if (between != null) ...[between!, SizedBox(height: betweenGap)],
            PlayerTitleRow(
              controller: controller,
              current: current,
              showMore: showMore,
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        // The cover and the title under it are one block, in the middle of the place above the controls, as in Apple
        // Music. The title keeps its size and the cover is what gives way when the screen is short
        final side = min(
          artSize,
          max(0.0, box.maxHeight - _titleHeight - gap - bottom),
        );
        // A lowered block has what room is over above it; half of that goes between the cover and what is under it
        // instead, so that the cover is not left far from the top of its place. The lines the title can take are counted
        final twoLines =
            side >= artSize &&
            box.maxHeight - side - gap - _titleHeight - bottom >= 32;
        final slack =
            box.maxHeight -
            side -
            gap -
            _titleHeight -
            bottom -
            (twoLines ? 32 : 0);
        final lift = lowered && side >= artSize ? max(0.0, slack) / 2 : 0.0;
        // When even the title is a little too tall for the place (the keyboard is up), the block shrinks to fit
        return Align(
          alignment: lowered ? Alignment.bottomCenter : Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: box.maxWidth - 2 * margin,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: PlayerCoverArt(
                      controller: controller,
                      current: current,
                      size: side,
                    ),
                  ),
                  // With no room left for the cover the title is all there is
                  SizedBox(height: side > 0 ? gap + lift : 0),
                  if (between != null) ...[
                    between!,
                    SizedBox(height: betweenGap),
                  ],
                  PlayerTitleRow(
                    controller: controller,
                    current: current,
                    showMore: showMore,
                    // A second line is for a screen where the cover keeps its size with it: one line of the title is
                    // taller than [_titleHeight] by about 32 dp
                    wrapLines: twoLines ? 2 : 1,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// About the height of the title, the artist and the heart under the cover.
const _titleHeight = 64.0;

/// The space between the cover and the title under it.
const _coverGap = 28.0;

/// A panel in place of the cover, under a small cover and the title so that the song stays in view. The other styles of
/// the upright player use it too.
class PlayerPanelStage extends StatelessWidget {
  const PlayerPanelStage({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onCover,
  });

  final RoomController controller;
  final QueueEntry current;
  final NowPlayingPanel panel;
  final VoidCallback onCover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final look = PlayerLookScope.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(playerMargin, 14, 20, 8),
          child: Row(
            children: [
              Semantics(
                button: true,
                label: S.showCover,
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: onCover,
                  // Even in a browser's Video mode: YouTube asks for a frame of 200 pixels, which is not the room a small
                  // cover has, so the frame is hidden here (it plays on) as it is in Audio and under the closed player
                  child: Artwork(url: current.thumb, size: 56, radius: 10),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      current.title,
                      style: theme.titleMedium,
                      rounds: MarqueeText.playerRounds,
                    ),
                    MarqueeText(
                      current.artist,
                      style: theme.bodyMedium?.copyWith(
                        color: look.quietArtist ? p.textSecondary : p.link,
                      ),
                      rounds: MarqueeText.playerRounds,
                    ),
                  ],
                ),
              ),
              LikeButton(track: current, size: 24, star: look.star),
              PlayerMoreButton(controller: controller, current: current),
            ],
          ),
        ),
        Expanded(
          child: switch (panel) {
            // The lines go up under the song above them: they fade out there, not cut off at its foot
            NowPlayingPanel.lyrics => EdgeFade(
              top: 24,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: playerMargin),
                child: LyricsView(controller: controller, track: current),
              ),
            ),
            NowPlayingPanel.comments => Padding(
              padding: const EdgeInsets.symmetric(horizontal: playerMargin),
              child: CommentsView(controller: controller, track: current),
            ),
            // The queue has 20 of its own at each side, and the song above it 32: the difference is made up here
            _ => Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: playerMargin - 20,
              ),
              child: UpNextView(controller: controller),
            ),
          },
        ),
      ],
    );
  }
}
