import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_settings.dart';
import '../data/models.dart';
import '../data/room_controller.dart';
import '../theme/theme.dart';
import 'player/apple_music_player.dart';
import 'player/classic_player.dart';
import 'player/look.dart';
import 'player/parts.dart';
import 'player/spotify_player.dart';
import 'player/video_controls.dart';
import 'player_sheet.dart';
import 'scope.dart';
import 'widgets/flat_backdrop.dart';
import 'widgets/player_backdrop.dart';
import 'widgets/reactions.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppScope.of(context).settings;
    return ListenableBuilder(
      // The style has a notifier of its own (the accent, which the dark theme of the cards is made in, is in the settings)
      listenable: Listenable.merge([settings, settings.playerStyleListenable]),
      builder: (context, _) {
        final style = settings.playerStyle;
        final dark = Theme.of(context).brightness == Brightness.dark;
        // Icons in the status bar and the navigation bar that show on the backdrop, light or dark like the app
        final icons = dark ? Brightness.light : Brightness.dark;
        final page = AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarIconBrightness: icons,
            systemNavigationBarIconBrightness: icons,
          ),
          child: _PlayerPage(style: style),
        );
        return page;
      },
    );
  }
}

class _PlayerPage extends StatelessWidget {
  const _PlayerPage({required this.style});

  final PlayerStyle style;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final sheet = PlayerSheetScope.of(context);
    return PlayerPull(
      child: KeyedSubtree(
        key: sheet.pageRoot,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final current = controller.snapshot.current;
              if (current == null) {
                // The queue emptied while the sheet was open
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => sheet.close(),
                );
                return const SizedBox.shrink();
              }
              return _Body(
                controller: controller,
                current: current,
                style: style,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({
    required this.controller,
    required this.current,
    required this.style,
  });

  final RoomController controller;
  final QueueEntry current;
  final PlayerStyle style;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  /// Opens on the panel the player bar of a wide screen was asked for, if it was.
  late NowPlayingPanel _panel = switch (PlayerSheetScope.of(context)
      .takePanel()) {
    PlayerPanel.lyrics => NowPlayingPanel.lyrics,
    PlayerPanel.upNext => NowPlayingPanel.upNext,
    null => NowPlayingPanel.cover,
  };

  RoomController get _c => widget.controller;

  PlayerSheetController? _sheet;

  ThemeData? _baseTheme;
  ThemeData? _coverTheme;

  /// The theme of the app with the quiet colours made for what is on a cover. Made again only when the app's own
  /// theme changes: a new one at every build would make everything under it build again.
  ThemeData _onCoverTheme(BuildContext context) {
    final base = Theme.of(context);
    if (!identical(base, _baseTheme)) {
      _baseTheme = base;
      _coverTheme = base.copyWith(
        extensions: [SapocheTheme(context.palette.onCover)],
      );
    }
    return _coverTheme!;
  }

  /// Back with lyrics or the queue shown goes to the cover first; the player closes on the next one.
  bool _stepBack() {
    if (_panel == NowPlayingPanel.cover) return false;
    setState(() => _panel = NowPlayingPanel.cover);
    return true;
  }

  @override
  void dispose() {
    if (_sheet?.stepBack == _stepBack) _sheet?.stepBack = null;
    super.dispose();
  }

  /// A second touch on the button of the panel that is open goes back to the cover.
  void _show(NowPlayingPanel panel) =>
      setState(() => _panel = _panel == panel ? NowPlayingPanel.cover : panel);

  /// Whether the screen was on its side at the last look, to see the phone being turned.
  bool? _wasLandscape;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheet = PlayerSheetScope.of(context)..stepBack = _stepBack;
    final media = MediaQuery.of(context);
    final landscape = media.orientation == Orientation.landscape;
    final turned = _wasLandscape == false && landscape;
    _wasLandscape = landscape;
    // A phone turned on its side while the picture plays shows it across the whole screen, as video apps do. A tablet
    // has room for the picture beside the controls.
    if (turned &&
        !kIsWeb &&
        _c.snapshot.video &&
        media.size.shortestSide < 600 &&
        PlayerSheetScope.of(context).position.value == 1 &&
        !VideoFullScreen.open.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openVideoFullScreen(context, _c, turned: true);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final look = PlayerLook.of(widget.style);
    // The full cover runs up under the status bar, whose icons are then on the picture: light ones
    final bleed =
        widget.style == PlayerStyle.appleMusic &&
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final onPicture =
        bleed && _panel == NowPlayingPanel.cover && !_c.snapshot.video;
    void choose(NowPlayingPanel panel) => setState(() => _panel = panel);
    Widget player() => switch (widget.style) {
      PlayerStyle.classic => ClassicPlayer(
        controller: _c,
        current: widget.current,
        panel: _panel,
        onPanel: _show,
        onChoose: choose,
      ),
      PlayerStyle.spotify => SpotifyPlayer(
        controller: _c,
        current: widget.current,
        panel: _panel,
        onPanel: _show,
        onChoose: choose,
      ),
      PlayerStyle.appleMusic => AppleMusicPlayer(
        controller: _c,
        current: widget.current,
        panel: _panel,
        onPanel: _show,
        onChoose: choose,
      ),
    };
    final page = PlayerLookScope(
      look: look,
      onPanel: choose,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The colours drift while the song plays, as Apple Music's do
          if (look.flatBackdrop)
            FlatBackdrop(coverUrl: widget.current.thumb)
          else
            ListenableBuilder(
              listenable: _c.playState,
              builder: (context, _) => PlayerBackdrop(
                coverUrl: widget.current.thumb,
                moving: _c.isPlaying,
                // The full cover melts into the colours: in the light theme they are kept strong, not pale
                vivid: widget.style == PlayerStyle.appleMusic,
              ),
            ),
          // On its side the phone has no height for one column: the cover goes beside the controls instead. The
          // safe area also keeps both clear of a notch at the side. Reactions in the room fly up over all of it.
          // What is on the colours of the cover is in the colours made for it (`Palette.onCover`), not in the greys
          // of a plain page
          Theme(
            data: _onCoverTheme(context),
            child: ReactionShower(
              controller: _c,
              child: SafeArea(top: !bleed, child: player()),
            ),
          ),
        ],
      ),
    );
    return onPicture
        ? AnnotatedRegion<SystemUiOverlayStyle>(
            value: const SystemUiOverlayStyle(
              statusBarIconBrightness: Brightness.light,
            ),
            child: page,
          )
        : page;
  }
}
