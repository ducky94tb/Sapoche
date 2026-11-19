import 'package:flutter/widgets.dart';

import '../../data/app_settings.dart';
import 'parts.dart' show NowPlayingPanel;

/// What the middle button of the transport row looks like.
enum PlayDisc {
  /// A disc in the accent of the app, as the player has always had.
  accent,

  /// A white disc with a dark glyph.
  white,

  /// The glyph alone.
  bare,
}

/// Which buttons the row of the full player holds.
enum ToolbarKind {
  /// Lyrics, the queue, the comments, the sleep timer and the output.
  classic,

  /// The song's info, where the sound goes and the comments on the left; adding to a playlist and the queue on the
  /// right. Lyrics are a card below the cover, not a button.
  face,

  /// Lyrics, then a pill of where the sound goes, the sleep timer and the comments, then the queue.
  plain,
}

/// The part of the full player's drawing that changes from one style to another. The places of the cover, the buttons
/// and the panels are the same in the three styles on a screen on its side and in a roomy window; only what is in this
/// class differs there. The pieces the styles share read it from [PlayerLookScope].
class PlayerLook {
  const PlayerLook({
    required this.style,
    required this.coverRadius,
    required this.coverShrinks,
    required this.disc,
    required this.shuffleRepeat,
    required this.thinBar,
    required this.toolbar,
    required this.flatBackdrop,
    required this.bigLyrics,
    this.star = false,
    this.rewindGlyphs = false,
    this.quietArtist = false,
    this.compactTitle = false,
  });

  final PlayerStyle style;

  /// Corner radius of the cover.
  final double coverRadius;

  /// Whether the cover grows and shrinks with playing and pausing.
  final bool coverShrinks;
  final PlayDisc disc;

  /// Whether shuffle and repeat are on the face of the player, either side of the play button.
  final bool shuffleRepeat;

  /// A thin seek bar with a round thumb.
  final bool thinBar;
  final ToolbarKind toolbar;

  /// One colour from the cover fading down to near black, standing still, in place of the colours that drift.
  final bool flatBackdrop;

  /// The words of the song a size larger.
  final bool bigLyrics;

  /// A star in place of the heart for keeping the song.
  final bool star;

  /// Previous and next drawn as a double triangle, the glyphs of rewinding and forwarding.
  final bool rewindGlyphs;

  /// The artist under the title in the quiet colour of the text, not the colour of a link.
  final bool quietArtist;

  /// The title of the song a little smaller.
  final bool compactTitle;

  static const classic = PlayerLook(
    style: PlayerStyle.classic,
    coverRadius: 16,
    coverShrinks: true,
    disc: PlayDisc.accent,
    shuffleRepeat: false,
    thinBar: false,
    toolbar: ToolbarKind.classic,
    flatBackdrop: false,
    bigLyrics: false,
  );

  static const spotify = PlayerLook(
    style: PlayerStyle.spotify,
    coverRadius: 6,
    coverShrinks: false,
    disc: PlayDisc.accent,
    shuffleRepeat: true,
    thinBar: true,
    toolbar: ToolbarKind.classic,
    flatBackdrop: true,
    bigLyrics: false,
    quietArtist: true,
    compactTitle: true,
  );

  static const appleMusic = PlayerLook(
    style: PlayerStyle.appleMusic,
    coverRadius: 12,
    coverShrinks: true,
    disc: PlayDisc.bare,
    shuffleRepeat: false,
    thinBar: false,
    toolbar: ToolbarKind.plain,
    flatBackdrop: false,
    bigLyrics: true,
    star: true,
    rewindGlyphs: true,
    quietArtist: true,
    compactTitle: true,
  );

  /// This look with the cover drawn another way: the full-width cover has no corners and does not shrink.
  PlayerLook copyWith({double? coverRadius, bool? coverShrinks}) => PlayerLook(
    style: style,
    coverRadius: coverRadius ?? this.coverRadius,
    coverShrinks: coverShrinks ?? this.coverShrinks,
    disc: disc,
    shuffleRepeat: shuffleRepeat,
    thinBar: thinBar,
    toolbar: toolbar,
    flatBackdrop: flatBackdrop,
    bigLyrics: bigLyrics,
    star: star,
    rewindGlyphs: rewindGlyphs,
    quietArtist: quietArtist,
    compactTitle: compactTitle,
  );

  static PlayerLook of(PlayerStyle style) => switch (style) {
    PlayerStyle.classic => classic,
    PlayerStyle.spotify => spotify,
    PlayerStyle.appleMusic => appleMusic,
  };
}

/// Hands the look of the player, and the way to open one of its panels, to the pieces under it. Without one above them
/// (the small player, a test of one piece) they are drawn as the classic player is.
class PlayerLookScope extends InheritedWidget {
  const PlayerLookScope({
    super.key,
    required this.look,
    required this.onPanel,
    this.docked = false,
    required super.child,
  });

  final PlayerLook look;

  /// The player is the card that stands beside the pages, which is always there: no handle to pull it down, no way out.
  final bool docked;

  /// Shows that panel, whatever is open.
  final ValueChanged<NowPlayingPanel> onPanel;

  static PlayerLook of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerLookScope>()?.look ??
      PlayerLook.classic;

  static bool dockedOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PlayerLookScope>()?.docked ??
      false;

  static ValueChanged<NowPlayingPanel>? panelOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PlayerLookScope>()?.onPanel;

  @override
  bool updateShouldNotify(PlayerLookScope old) =>
      look != old.look || docked != old.docked;
}
