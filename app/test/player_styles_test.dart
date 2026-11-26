import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/player/apple_music_player.dart';
import 'package:sapoche/ui/player/classic_player.dart';
import 'package:sapoche/ui/player/parts.dart';
import 'package:sapoche/ui/player/spotify_player.dart';
import 'package:sapoche/ui/player/lyrics_ticker.dart';
import 'package:sapoche/ui/player/lyrics_view.dart';
import 'package:sapoche/ui/player_sheet.dart';
import 'package:sapoche/ui/scope.dart';
import 'package:sapoche/ui/widgets/artwork.dart';
import 'package:sapoche/ui/widgets/flat_backdrop.dart';
import 'package:sapoche/ui/widgets/player_backdrop.dart';
import 'package:sapoche/ui/widgets/volume_bar.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'pump_app.dart';

/// Opens the full player in [style] on the first song of a room, as `openPlayer` does for the classic one.
Future<FakeBackend> openStyled(
  WidgetTester tester,
  PlayerStyle style, {
  bool inRoom = false,
  Lyrics? lyrics,
  ThemeMode mode = ThemeMode.light,
  bool video = false,
  int positionMs = 4000,
}) async {
  final (backend, _) = await pumpApp(
    tester,
    mode: mode,
    prefs: {'player_style': style.name},
  );
  backend.lyricsResult = lyrics;
  backend.emit(StateEvent(sampleRoom(video: video)));
  backend.emit(
    PositionEvent(
      PlayerPosition(
        playing: true,
        positionMs: positionMs,
        durationMs: 200000,
        audioFormat: const AudioFormat(codec: 'Opus', kbps: 131, hz: 48000),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  await tapMiniPlayer(tester);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  return backend;
}

/// The scroll view of the cards: the app has others under the player.
Finder get pageScroll => find.descendant(
  of: find.byType(SpotifyPlayer),
  matching: find.byType(CustomScrollView),
);

Finder cardTitle(String title) =>
    find.descendant(of: find.byType(SpotifyPlayer), matching: find.text(title));

Finder tip(String start) => find.byWidgetPredicate(
  (w) => w is IconButton && (w.tooltip ?? '').startsWith(start),
);

void main() {
  testWidgets('the classic player is there when it is chosen', (tester) async {
    await openStyled(tester, PlayerStyle.classic);
    expect(find.byType(ClassicPlayer), findsOneWidget);
    expect(find.byType(SpotifyPlayer), findsNothing);
    expect(find.byType(AppleMusicPlayer), findsNothing);
    expect(find.byType(PlayerBackdrop), findsOneWidget);
    expect(tip(S.shuffle), findsNothing);
  });

  testWidgets('a phone that has never chosen has the full cover', (
    tester,
  ) async {
    // pumpApp sets the classic player for the tests: a fresh phone is read here as the app reads it
    SharedPreferences.setMockInitialValues({});
    final fresh = await AppSettings.load();
    expect(fresh.playerStyle, PlayerStyle.appleMusic);
    expect(PlayerStyle.defaultStyle, PlayerStyle.appleMusic);
  });

  testWidgets('a value that is not a style is the default too', (tester) async {
    final (_, _) = await pumpApp(tester, prefs: {'player_style': 'neon'});
    final model = AppScope.of(tester.element(find.byType(Scaffold).first));
    expect(model.settings.playerStyle, PlayerStyle.appleMusic);
  });

  testWidgets('changing the style changes the player that is open', (
    tester,
  ) async {
    await openStyled(tester, PlayerStyle.classic);
    final model = AppScope.of(tester.element(find.byType(NowPlayingPage)));
    model.settings.playerStyle = PlayerStyle.spotify;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SpotifyPlayer), findsOneWidget);
    expect(find.byType(FlatBackdrop), findsOneWidget);
    model.settings.playerStyle = PlayerStyle.appleMusic;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AppleMusicPlayer), findsOneWidget);
    expect(find.byType(PlayerBackdrop), findsOneWidget);
  });

  testWidgets('choosing a style does not wake what listens to the settings', (
    tester,
  ) async {
    // The whole app listens to the settings (the theme, the language): a style chosen must not build it all again
    await pumpApp(tester);
    final model = AppScope.of(tester.element(find.byType(Scaffold).first));
    var woken = 0;
    model.settings.addListener(() => woken++);
    var styled = 0;
    model.settings.playerStyleListenable.addListener(() => styled++);
    model.settings.playerStyle = PlayerStyle.spotify;
    model.settings.playerStyle = PlayerStyle.spotify;
    model.settings.playerStyle = PlayerStyle.appleMusic;
    expect(woken, 0);
    expect(styled, 2, reason: 'once for each change, none for the same style');
  });

  testWidgets('the settings offer the three styles and keep the choice', (
    tester,
  ) async {
    await pumpApp(tester);
    await openTopic(tester, 'appearance');
    for (final style in PlayerStyle.values) {
      expect(
        find.byKey(ValueKey('player-style-${style.name}')),
        findsOneWidget,
      );
    }
    await tester.ensureVisible(
      find.byKey(const ValueKey('player-style-appleMusic')),
    );
    await tester.tap(find.byKey(const ValueKey('player-style-appleMusic')));
    await tester.pumpAndSettle();
    final model = AppScope.of(tester.element(find.byType(Scaffold).first));
    expect(model.settings.playerStyle, PlayerStyle.appleMusic);
    expect(find.text('Full cover'), findsOneWidget);
  });

  group('cards', () {
    testWidgets('the head names the room, or who made a song that has no album', (
      tester,
    ) async {
      final backend = await openStyled(tester, PlayerStyle.spotify);
      final artist = sampleRoom().current!.artist;
      // In the room the head names the room
      expect(find.text(S.room), findsOneWidget);
      final inRoom = find.text(artist).evaluate().length;
      // On its own, with a song that has no album: the artist too, so that the head is not left with only "Now playing"
      backend.emit(StateEvent(sampleRoom(local: true)));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(S.room), findsNothing);
      expect(find.text(artist), findsNWidgets(inRoom + 1));
    });

    testWidgets('the face has shuffle and repeat by the play button', (
      tester,
    ) async {
      final backend = await openStyled(tester, PlayerStyle.spotify);
      expect(tip(S.shuffle), findsOneWidget);
      expect(tip('Repeat'), findsOneWidget);
      await tester.tap(tip(S.shuffle));
      await tester.pump();
      expect(
        backend.calls.any((c) => c.toLowerCase().contains('shuffle')),
        isTrue,
      );
      // The row below: where the sound goes, the sleep timer and the comments, then the playlist and the queue. Lyrics
      // are a card, and the song's info is in the "…" of the song
      for (final label in [
        S.playOn,
        S.sleepTimer,
        S.youtubeComments,
        S.addToPlaylist,
        S.upNext,
      ]) {
        expect(find.byTooltip(label), findsOneWidget, reason: label);
      }
      expect(find.byTooltip(S.lyrics), findsNothing);
      expect(find.byTooltip(S.songInfo), findsNothing);
      // Tapping the sleep timer button opens the sheet and setting a timer lights it up without overflowing
      await tester.tap(find.byTooltip(S.sleepTimer));
      await tester.pumpAndSettle();
      expect(find.text(S.sleepTimer), findsOneWidget);
      await tester.tap(find.text(S.sleepSongEnd));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('sleep song 0'));
      backend.emit(const SleepEvent(SleepState(mode: SleepMode.song)));
      await tester.pumpAndSettle();
      expect(find.byTooltip(S.sleepStopsAfterSong), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The play button is a disc in the accent of the app, not a white one
      final disc = find.ancestor(
        of: find.byIcon(Icons.pause_rounded),
        matching: find.byType(Material),
      );
      expect(
        tester.widget<Material>(disc.first).color,
        isNot(const Color(0xFFFFFFFF)),
      );
      expect(
        tester.widget<Material>(disc.first).color,
        isNot(Colors.transparent),
      );
    });

    testWidgets('the cover is as wide as the title', (tester) async {
      await openStyled(tester, PlayerStyle.spotify);
      final screen =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final cover = tester.getRect(
        find.byKey(
          PlayerSheetScope.of(tester.element(find.byType(SpotifyPlayer)))
              .pageCover,
        ),
      );
      expect(cover.width, closeTo(screen - 2 * 22, 1));
      expect(cover.left, closeTo(22, 1), reason: 'where the title starts');
    });

    testWidgets('a finger turned back up brings the player back up with it', (
      tester,
    ) async {
      await openStyled(tester, PlayerStyle.spotify);
      final sheet = PlayerSheetScope.of(
        tester.element(find.byType(SpotifyPlayer)),
      );
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: pageScroll, matching: find.byType(Scrollable)),
      );
      final gesture = await tester.startGesture(const Offset(200, 500));
      await gesture.moveBy(const Offset(0, 100));
      await gesture.moveBy(const Offset(0, 150));
      await tester.pump();
      final low = sheet.position.value;
      expect(low, lessThan(1), reason: 'the player is on its way down');
      // The finger turns: the player rises with it, and the page under it has not scrolled
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(sheet.position.value, greaterThan(low));
      expect(scroll.position.pixels, 0);
      // All the way up and on: the page scrolls
      await gesture.moveBy(const Offset(0, -400));
      await gesture.moveBy(const Offset(0, -300));
      await tester.pump();
      expect(sheet.position.value, 1);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(sheet.position.value, 1);
      expect(scroll.position.pixels, greaterThan(0));
    });

    testWidgets('only the top edge of the lyrics card shows under the face', (
      tester,
    ) async {
      await openStyled(tester, PlayerStyle.spotify);
      final screen =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final card = tester.getRect(
        find
            .ancestor(of: cardTitle(S.lyrics), matching: find.byType(Material))
            .first,
      );
      expect(card.top, lessThan(screen), reason: 'its edge is in view');
      expect(card.top, greaterThan(screen - 48), reason: 'only a little of it');
    });

    testWidgets('the name of the device is not on the face', (tester) async {
      final backend = await openStyled(tester, PlayerStyle.spotify);
      backend.emit(
        const OutputEvent(AudioOutput(kind: 'bluetooth', name: 'AirPods Pro')),
      );
      await tester.pump();
      expect(find.text('AirPods Pro'), findsNothing);
    });

    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('it follows the theme of the app (${mode.name})', (
        tester,
      ) async {
        await openStyled(tester, PlayerStyle.spotify, mode: mode);
        expect(
          Theme.of(tester.element(find.byType(SpotifyPlayer))).brightness,
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
        );
      });
    }

    testWidgets(
      'scrolling shows the cards and a touch opens a page that Back closes',
      (tester) async {
        await openStyled(tester, PlayerStyle.spotify);
        await tester.drag(pageScroll, const Offset(0, -700));
        await tester.pump(const Duration(milliseconds: 400));
        expect(cardTitle(S.lyrics), findsOneWidget);
        // The queue card, then its page
        await tester.ensureVisible(cardTitle(S.upNext));
        await tester.pump();
        await tester.tap(cardTitle(S.upNext));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(PlayerPanelStage), findsOneWidget);
        expect(await tester.binding.handlePopRoute(), isTrue);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(PlayerPanelStage), findsNothing);
        expect(pageScroll, findsOneWidget, reason: 'back on the face');
        expect(
          PlayerSheetScope.of(tester.element(find.byType(SpotifyPlayer)))
              .position
              .value,
          1,
        );
      },
    );

    testWidgets(
      'a pull down from the top of the page closes the player, in the middle it scrolls',
      (tester) async {
        await openStyled(tester, PlayerStyle.spotify);
        final sheet = PlayerSheetScope.of(
          tester.element(find.byType(SpotifyPlayer)),
        );
        // In the middle of the page the same pull only scrolls
        await tester.drag(pageScroll, const Offset(0, -900));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.drag(pageScroll, const Offset(0, 150));
        await tester.pump(const Duration(milliseconds: 400));
        expect(sheet.position.value, 1);
        // At the top it closes
        await tester.fling(pageScroll, const Offset(0, 900), 2000);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 800));
        expect(sheet.position.value, 0);
      },
    );
  });

  group('full cover', () {
    testWidgets(
      'on a phone on its side the picture is a square as wide as the card, not a wide crop with the black of a 16:9 frame',
      (tester) async {
        // A song whose thumbnail is a square cover held in the black of a 16:9 frame shows the black at the sides of
        // the card, and the square's edges, if the picture is cropped wide
        await openStyled(tester, PlayerStyle.appleMusic);
        await resize(tester, 844, 390);
        final picture = find.descendant(
          of: find.byType(AppleMusicPlayer),
          matching: find.byType(Artwork),
        );
        expect(picture, findsOneWidget);
        final box = tester.getRect(picture);
        final card = tester.getRect(find.byType(AppleMusicPlayer));
        expect(box.width, closeTo(card.width, 1));
        expect(box.height, closeTo(box.width, 1), reason: 'a square, cut at the top and foot');
      },
    );

    testWidgets(
      'the cover ends on a whole device pixel, so that no row of it is left unmasked',
      (tester) async {
        // A tablet whose pixel ratio is not a whole number (the Tab S7): a cover that ends part-way through a pixel row
        // leaves that row partly unmasked, and the picture's last row shows as a thin line across the screen
        addTearDown(tester.view.reset);
        await openStyled(tester, PlayerStyle.appleMusic);
        tester.view.devicePixelRatio = 1.7125;
        tester.view.physicalSize = const Size(1600, 2560);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        final masks = find.descendant(
          of: find.byType(AppleMusicPlayer),
          matching: find.byType(ShaderMask),
        );
        expect(masks, findsWidgets);
        // The cover's (the title's fade at its edge is small)
        final tall = [
          for (final mask in masks.evaluate())
            (mask.renderObject! as RenderBox).size.height,
        ].where((h) => h > 300);
        expect(tall, isNotEmpty);
        for (final h in tall) {
          final px = h * 1.7125;
          expect((px - px.roundToDouble()).abs(), lessThan(1e-6));
        }
      },
    );

    testWidgets(
      'lyrics, a pill of output, sleep timer and comments, and the queue; plain buttons',
      (tester) async {
        await openStyled(tester, PlayerStyle.appleMusic);
        for (final label in [
          S.lyrics,
          S.playOn,
          S.sleepTimer,
          S.youtubeComments,
          S.upNext,
        ]) {
          expect(find.byTooltip(label), findsOneWidget, reason: label);
        }
        // All five are in one pill: the lyrics and the queue are not off on their own
        final pill = find.ancestor(
          of: find.byTooltip(S.lyrics),
          matching: find.byWidgetPredicate(
            (w) => w is DecoratedBox && w.decoration is ShapeDecoration,
          ),
        );
        for (final label in [
          S.playOn,
          S.sleepTimer,
          S.youtubeComments,
          S.upNext,
        ]) {
          expect(
            find.descendant(of: pill.first, matching: find.byTooltip(label)),
            findsOneWidget,
            reason: label,
          );
        }
        // The quality of the sound sits between the two times
        expect(find.textContaining('kbps'), findsOneWidget);
        expect(tip(S.shuffle), findsNothing);
        expect(find.byType(VolumeBar), findsOneWidget);
        // The play button has no disc
        final play = find.ancestor(
          of: find.byIcon(Icons.pause_rounded),
          matching: find.byType(Material),
        );
        expect(tester.widget<Material>(play.first).color, Colors.transparent);
        // The cover is as wide as the screen
        final cover = tester.getRect(
          find.byKey(
            PlayerSheetScope.of(tester.element(find.byType(AppleMusicPlayer)))
                .pageCover,
          ),
        );
        expect(
          cover.width,
          tester.view.physicalSize.width / tester.view.devicePixelRatio,
        );
      },
    );

    testWidgets('the play button is as large as the two beside it', (
      tester,
    ) async {
      await openStyled(tester, PlayerStyle.appleMusic);
      final skip = tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.fast_forward_rounded).first,
          )
          .iconSize!;
      final play = tester
          .widget<Icon>(find.byIcon(Icons.pause_rounded).first)
          .size!;
      expect(play, closeTo(skip, skip * 0.12), reason: 'one size, to the eye');
    });

    testWidgets('the picture is blurred under the status bar', (tester) async {
      final (backend, _) = await pumpApp(
        tester,
        prefs: {'player_style': PlayerStyle.appleMusic.name},
      );
      tester.view
        ..padding = const FakeViewPadding(top: 48)
        ..viewPadding = const FakeViewPadding(top: 48);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tapMiniPlayer(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      // A blurred copy of the cover, in a mask that thins out to nothing below the bar (24 dp: 48 physical pixels at 2 per
      // dp, and 40 more): no layer with an edge of its own
      final blur = find.descendant(
        of: find.byType(AppleMusicPlayer),
        matching: find.byType(ImageFiltered),
      );
      expect(blur, findsOneWidget);
      final mask = find.ancestor(of: blur, matching: find.byType(ShaderMask));
      expect(mask, findsWidgets);
      final reach = tester.getSize(mask.first).height;
      expect(reach, 24 + 40);
      expect(tester.getTopLeft(mask.first).dy, 0);
    });

    testWidgets('the comments open from the pill', (tester) async {
      await openStyled(tester, PlayerStyle.appleMusic);
      await tester.tap(find.byTooltip(S.youtubeComments));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PlayerPanelStage), findsOneWidget);
      expect(await tester.binding.handlePopRoute(), isTrue);
    });
  });

  group('audio and video', () {
    for (final style in [PlayerStyle.spotify, PlayerStyle.appleMusic]) {
      testWidgets('$style: a button goes to the picture and back', (
        tester,
      ) async {
        final backend = await openStyled(tester, style);
        await tester.tap(find.byTooltip(S.modeVideo));
        await tester.pump();
        expect(backend.calls, contains('video true'));
      });

      testWidgets(
        '$style: while the picture shows the button is for the cover',
        (tester) async {
          final backend = await openStyled(tester, style, video: true);
          expect(find.byTooltip(S.modeVideo), findsNothing);
          await tester.tap(find.byTooltip(S.modeAudio));
          await tester.pump();
          expect(backend.calls, contains('video false'));
        },
      );

      // The picture takes the place of the cover, and everything else is where it was: nothing leaves the screen or
      // overlaps, on a phone upright and on its side, on a short phone and in a window with room
      for (final (width, height) in [
        (360.0, 800.0),
        (411.0, 914.0),
        (360.0, 640.0),
        (844.0, 390.0),
        (800.0, 360.0),
        (1280.0, 800.0),
      ]) {
        testWidgets('$style, the picture, ${width}x$height', (tester) async {
          await openStyled(tester, style, video: true);
          await resize(tester, width, height);
          expect(tester.takeException(), isNull);
          final frame = find.byKey(const ValueKey('video'));
          expect(frame, findsOneWidget, reason: 'the picture is there');
          final picture = tester.getRect(frame);
          expect(picture.width, greaterThan(100));
          expect(picture.left, greaterThanOrEqualTo(-0.5));
          expect(picture.right, lessThanOrEqualTo(width + 0.5));
          expect(picture.top, greaterThanOrEqualTo(-0.5));
          expect(picture.bottom, lessThanOrEqualTo(height + 0.5));
          // The seek bar and the play button are in view and below the picture (or beside it on its side)
          final bar = tester.getRect(
            find.bySemanticsLabel(S.songPosition).first,
          );
          expect(bar.bottom, lessThanOrEqualTo(height + 0.5));
          expect(bar.overlaps(picture), isFalse, reason: 'bar and picture');
          expect(find.byTooltip(S.modeAudio), findsOneWidget);
        });
      }
    }
  });

  group('on its side every style has the buttons of its look, in a card beside the pages', () {
    /// What is in the card of the player: the pages beside it have buttons of their own.
    Finder inCard(Finder finder) =>
        find.descendant(of: find.byType(NowPlayingPage), matching: finder);

    for (final style in PlayerStyle.values) {
      testWidgets('$style', (tester) async {
        await openStyled(tester, style);
        await resize(tester, 844, 390);
        expect(tester.takeException(), isNull);
        expect(find.byType(NowPlayingPage), findsOneWidget);
        // No row of icons and no volume: the comments, where the sound goes and the sleep timer are in the "…"
        for (final label in [S.playOn, S.youtubeComments, S.sleepTimer]) {
          expect(
            inCard(find.byTooltip(label)),
            findsNothing,
            reason: '$style $label',
          );
        }
        expect(inCard(find.byType(VolumeBar)), findsNothing);
        // The cards have no button for the lyrics or the queue: they are cards, and shuffle and repeat are on the face
        for (final label in [S.lyrics, S.upNext]) {
          expect(
            inCard(find.byTooltip(label)),
            style == PlayerStyle.spotify ? findsNothing : findsOneWidget,
            reason: '$style $label',
          );
        }
        expect(
          inCard(tip(S.shuffle)),
          style == PlayerStyle.spotify ? findsOneWidget : findsNothing,
        );
      });
    }

    testWidgets(
      'the cards: a touch on the lyrics card opens the lyrics, and the small cover goes back',
      (tester) async {
        await openStyled(tester, PlayerStyle.spotify);
        await resize(tester, 844, 390);
        // The cards are under the cover and the song: only the top edge of the first shows until the column is scrolled
        await tester.drag(
          find.descendant(
            of: find.byType(NowPlayingPage),
            matching: find.byType(SingleChildScrollView),
          ),
          const Offset(0, -150),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(
          find.descendant(
            of: find.byType(NowPlayingPage),
            matching: find.text(S.lyrics),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(LyricsView), findsOneWidget);
        await tester.tap(find.bySemanticsLabel(S.showCover));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(LyricsView), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('the lyrics run along with the song', () {
    const lyrics = Lyrics(
      lines: [
        LyricLine(0, 'line one'),
        LyricLine(4000, 'line two'),
        LyricLine(9000, 'line three'),
        LyricLine(14000, 'line four'),
        LyricLine(20000, 'line five'),
        LyricLine(26000, 'line six'),
      ],
    );

    /// The line that is lit: the only one of a lyric view at full strength.
    String lit(WidgetTester tester, Finder under) {
      final bright = tester
          .widgetList<AnimatedOpacity>(
            find.descendant(of: under, matching: find.byType(AnimatedOpacity)),
          )
          .where((o) => o.opacity == 1)
          .toList();
      expect(bright, hasLength(1));
      return (bright.single.child! as Text).data!;
    }

    Future<void> at(WidgetTester tester, FakeBackend backend, int ms) async {
      backend.emit(
        PositionEvent(
          PlayerPosition(playing: true, positionMs: ms, durationMs: 200000),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      // The old window finishes fading out in the frame after
      await tester.pump(const Duration(milliseconds: 400));
    }

    for (final style in [PlayerStyle.appleMusic, PlayerStyle.spotify]) {
      testWidgets('$style: one small line runs on the face of the player', (
        tester,
      ) async {
        final backend = await openStyled(tester, style, lyrics: lyrics);
        await tester.pump(const Duration(milliseconds: 600));
        final ticker = find.byType(LyricsTicker);
        expect(ticker, findsOneWidget);
        Finder text(String line) =>
            find.descendant(of: ticker, matching: find.text(line));
        await at(tester, backend, 5000);
        expect(text('line two'), findsOneWidget);
        expect(text('line three'), findsNothing, reason: 'one line, not two');
        await at(tester, backend, 15000);
        expect(text('line four'), findsOneWidget);
        expect(text('line five'), findsNothing);
        expect(text('line two'), findsNothing);
        // The line repaints every frame, so it has a layer of its own: the cover and the colours are not drawn again
        expect(
          find.descendant(of: ticker, matching: find.byType(RepaintBoundary)),
          findsWidgets,
        );
        // A touch opens the page of the lyrics
        await tester.tap(ticker);
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(LyricsView), findsOneWidget);
        expect(
          find.byType(LyricsTicker),
          findsNothing,
          reason: 'the page has them',
        );
      });
    }

    testWidgets(
      'a line longer than the place runs sideways, whole, with no dots',
      (tester) async {
        const long =
            'a line so long that the place for it cannot hold all of it at once without running sideways to the end';
        final backend = await openStyled(
          tester,
          PlayerStyle.spotify,
          // The song is before the long line when the player opens: it comes while the player is looked at
          positionMs: 1000,
          lyrics: const Lyrics(
            lines: [
              LyricLine(0, 'short'),
              LyricLine(4000, long),
              LyricLine(30000, 'after'),
            ],
          ),
        );
        await at(tester, backend, 4200);
        final ticker = find.byType(LyricsTicker);
        final text = tester.widget<Text>(
          find.descendant(of: ticker, matching: find.text(long)),
        );
        expect(
          text.overflow,
          TextOverflow.visible,
          reason: 'never cut with dots',
        );
        expect(text.maxLines, 1);
        double shift() => tester
            .widget<Transform>(
              find
                  .descendant(of: ticker, matching: find.byType(Transform))
                  .first,
            )
            .transform
            .getTranslation()
            .x;
        final first = shift();
        expect(first, 0, reason: 'it begins at its first word');
        // It stands at its start for a while, so that its first words can be read, before it runs
        await tester.pump(const Duration(milliseconds: 600));
        expect(shift(), 0, reason: 'still holding');
        await tester.pump(const Duration(seconds: 4));
        expect(shift(), lessThan(first), reason: 'it has run to the left');
        // The end of the line is in view by the time it is over: the run covers the whole of what did not fit
        await tester.pump(const Duration(seconds: 30));
        final end = shift();
        final width = tester
            .getSize(find.descendant(of: ticker, matching: find.text(long)))
            .width;
        final place = tester.getSize(ticker).width;
        expect(-end, closeTo(width - place, 1));
      },
    );

    testWidgets(
      'on the cards the cover is not left far from the top of its place',
      (tester) async {
        await openStyled(tester, PlayerStyle.spotify, lyrics: lyrics);
        await tester.pump(const Duration(milliseconds: 600));
        final cover = tester.getRect(
          find.byKey(
            PlayerSheetScope.of(tester.element(find.byType(SpotifyPlayer)))
                .pageCover,
          ),
        );
        final header = tester.getRect(find.text(S.nowPlaying.toUpperCase()));
        final line = tester.getRect(find.byType(LyricsTicker));
        // The room left over is shared: some above the cover and some between it and the line of the lyrics
        final above = cover.top - header.bottom;
        final between = line.top - cover.bottom;
        expect(between, greaterThan(14), reason: 'more than the least gap');
        expect(
          above,
          lessThanOrEqualTo((above + between) * 0.65),
          reason: 'not all of the room is above',
        );
      },
    );

    testWidgets('on the cards the song stands close to the seek bar', (
      tester,
    ) async {
      await openStyled(tester, PlayerStyle.spotify, lyrics: lyrics);
      await tester.pump(const Duration(milliseconds: 600));
      final artist = tester.getRect(find.text('Artist 0').first);
      final bar = tester.getRect(find.bySemanticsLabel(S.songPosition).first);
      // Not floating half way up the place above the bar: what is between them is a little more than the bar's own room
      expect(bar.top - artist.bottom, lessThan(40));
    });

    testWidgets('on the cards the line is between the cover and the title', (
      tester,
    ) async {
      await openStyled(tester, PlayerStyle.spotify, lyrics: lyrics);
      await tester.pump(const Duration(milliseconds: 600));
      final cover = tester.getRect(
        find.byKey(
          PlayerSheetScope.of(tester.element(find.byType(SpotifyPlayer)))
              .pageCover,
        ),
      );
      final ticker = tester.getRect(find.byType(LyricsTicker));
      final title = tester.getRect(find.text('Song 0').first);
      expect(ticker.top, greaterThanOrEqualTo(cover.bottom));
      // The title is not hard under the line of the lyrics: it has room of its own
      expect(title.top - ticker.bottom, greaterThanOrEqualTo(16));
    });

    testWidgets('a song whose lyrics have no times has no lines to run', (
      tester,
    ) async {
      await openStyled(
        tester,
        PlayerStyle.appleMusic,
        lyrics: const Lyrics(plain: 'only words, no times'),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(LyricsTicker), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(LyricsTicker),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
        reason: 'the place is not taken',
      );
    });

    testWidgets('full cover: the page of the lyrics moves from line to line', (
      tester,
    ) async {
      final backend = await openStyled(
        tester,
        PlayerStyle.appleMusic,
        lyrics: lyrics,
      );
      await tester.tap(find.byTooltip(S.lyrics));
      await tester.pump(const Duration(milliseconds: 600));
      final view = find.byType(LyricsView);
      await at(tester, backend, 5000);
      expect(lit(tester, view), 'line two');
      await at(tester, backend, 15000);
      expect(lit(tester, view), 'line four');
      await at(tester, backend, 27000);
      expect(lit(tester, view), 'line six');
    });

    testWidgets('cards: the lyrics card runs on its own, without opening it', (
      tester,
    ) async {
      final backend = await openStyled(
        tester,
        PlayerStyle.spotify,
        lyrics: lyrics,
      );
      await tester.drag(pageScroll, const Offset(0, -700));
      await tester.pump(const Duration(milliseconds: 600));
      final card = find.ancestor(
        of: cardTitle(S.lyrics),
        matching: find.byType(Material),
      );
      await at(tester, backend, 5000);
      expect(lit(tester, card.first), 'line two');
      await at(tester, backend, 15000);
      expect(lit(tester, card.first), 'line four');
      // Near the end the window keeps its size and the lit line is further down it
      await at(tester, backend, 27000);
      expect(lit(tester, card.first), 'line six');
    });
  });

  group('pulling the player down', () {
    /// How much of the cover shows while a finger holds the player part of the way down: 1 is the cover itself, 0 is
    /// that it is hidden and a flying square stands in for it.
    Future<double> coverWhilePulled(
      WidgetTester tester,
      PlayerStyle style,
    ) async {
      await openStyled(tester, style);
      final gesture = await tester.startGesture(const Offset(200, 400));
      await gesture.moveBy(const Offset(0, 150));
      await gesture.moveBy(const Offset(0, 150));
      await tester.pump();
      final sheet = PlayerSheetScope.of(
        tester.element(find.byType(NowPlayingPage)),
      );
      expect(sheet.inMotion, isTrue, reason: 'the player is on its way down');
      final shown = tester
          .widget<Opacity>(
            find
                .descendant(
                  of: find.byType(CoverSlot),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      await gesture.up();
      await tester.pumpAndSettle();
      return shown;
    }

    testWidgets('full cover: its own cover, with the melting foot, stays', (
      tester,
    ) async {
      expect(await coverWhilePulled(tester, PlayerStyle.appleMusic), 1);
    });

    testWidgets(
      'full cover: still stays after turning to landscape and back on a tablet',
      (tester) async {
        await openStyled(tester, PlayerStyle.appleMusic);
        await resize(tester, 800, 1280);
        await resize(tester, 1280, 800);
        await resize(tester, 800, 1280);
        final gesture = await tester.startGesture(const Offset(400, 500));
        await gesture.moveBy(const Offset(0, 150));
        await gesture.moveBy(const Offset(0, 150));
        await tester.pump();
        final sheet = PlayerSheetScope.of(
          tester.element(find.byType(NowPlayingPage)),
        );
        expect(sheet.inMotion, isTrue);
        final shown = tester
            .widget<Opacity>(
              find
                  .descendant(
                    of: find.byType(CoverSlot),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(shown, 1);
      },
    );

    testWidgets(
      'full cover: still stays after turning to landscape and back on a phone',
      (tester) async {
        await openStyled(tester, PlayerStyle.appleMusic);
        await resize(tester, 390, 844);
        await resize(tester, 844, 390);
        await resize(tester, 390, 844);
        final gesture = await tester.startGesture(const Offset(200, 400));
        await gesture.moveBy(const Offset(0, 150));
        await gesture.moveBy(const Offset(0, 150));
        await tester.pump();
        final sheet = PlayerSheetScope.of(
          tester.element(find.byType(NowPlayingPage)),
        );
        expect(sheet.inMotion, isTrue);
        final shown = tester
            .widget<Opacity>(
              find
                  .descendant(
                    of: find.byType(CoverSlot),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(shown, 1);
      },
    );

    testWidgets(
      'full cover: still stays when pulled down in a narrow landscape window',
      (tester) async {
        await openStyled(tester, PlayerStyle.appleMusic);
        await resize(tester, 640, 360);
        final gesture = await tester.startGesture(const Offset(320, 120));
        await gesture.moveBy(const Offset(0, 80));
        await gesture.moveBy(const Offset(0, 80));
        await tester.pump();
        final sheet = PlayerSheetScope.of(
          tester.element(find.byType(NowPlayingPage)),
        );
        expect(sheet.inMotion, isTrue);
        final shown = tester
            .widget<Opacity>(
              find
                  .descendant(
                    of: find.byType(CoverSlot),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(shown, 1);
      },
    );

    testWidgets(
      'full cover: still stays after switching to a panel and right back',
      (tester) async {
        await openStyled(tester, PlayerStyle.appleMusic);
        await tester.tap(find.byTooltip(S.lyrics));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byTooltip(S.lyrics));
        await tester.pump(const Duration(milliseconds: 400));
        final gesture = await tester.startGesture(const Offset(200, 400));
        await gesture.moveBy(const Offset(0, 150));
        await gesture.moveBy(const Offset(0, 150));
        await tester.pump();
        final shown = tester
            .widget<Opacity>(
              find
                  .descendant(
                    of: find.byType(CoverSlot),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity;
        await gesture.up();
        await tester.pumpAndSettle();
        expect(shown, 1);
      },
    );

    testWidgets('classic: the cover flies as it always has', (tester) async {
      expect(await coverWhilePulled(tester, PlayerStyle.classic), 0);
    });
  });

  group('full cover stays white-on-colour in the light theme', () {
    testWidgets('uses the dark on-cover palette and light system bars when the app is light', (
      tester,
    ) async {
      await openStyled(tester, PlayerStyle.appleMusic);
      final player = tester.element(find.byType(AppleMusicPlayer));
      expect(Theme.of(player).brightness, Brightness.dark);

      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.descendant(
          of: find.byType(NowPlayingPage),
          matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        ),
      );
      expect(region.value.statusBarIconBrightness, Brightness.light);
      expect(region.value.systemNavigationBarIconBrightness, Brightness.light);
      expect(region.value.statusBarBrightness, Brightness.dark);
    });

    testWidgets(
      'a sheet opened from it, as the sleep timer, is in the light theme of the app',
      (tester) async {
        await openStyled(tester, PlayerStyle.appleMusic);
        final app = tester.element(find.byType(NowPlayingPage));
        await tester.tap(find.byTooltip(S.sleepTimer));
        await tester.pumpAndSettle();
        final sheet = tester.element(find.text(S.sleepSongEnd));
        expect(Theme.of(sheet).brightness, Brightness.light);
        // The greys of a plain page, not the see-through ones made for a cover
        expect(sheet.palette.textSecondary, app.palette.textSecondary);
      },
    );

    testWidgets(
      'a sheet opened from it in the dark theme has the greys of a plain page',
      (tester) async {
        await openStyled(tester, PlayerStyle.appleMusic, mode: ThemeMode.dark);
        final app = tester.element(find.byType(NowPlayingPage));
        await tester.tap(find.byTooltip(S.sleepTimer));
        await tester.pumpAndSettle();
        final sheet = tester.element(find.text(S.sleepSongEnd));
        expect(Theme.of(sheet).brightness, Brightness.dark);
        expect(sheet.palette.textSecondary, app.palette.textSecondary);
      },
    );

    testWidgets('classic and cards still follow the light theme of the app', (
      tester,
    ) async {
      for (final style in [PlayerStyle.classic, PlayerStyle.spotify]) {
        await openStyled(tester, style);
        final backdrop = tester.element(find.byType(NowPlayingPage));
        expect(Theme.of(backdrop).brightness, Brightness.light);
        final inner = tester.element(
          find.descendant(
            of: find.byType(NowPlayingPage),
            matching: find.byType(TransportRow),
          ),
        );
        expect(Theme.of(inner).brightness, Brightness.light);
      }
    });
  });
}
