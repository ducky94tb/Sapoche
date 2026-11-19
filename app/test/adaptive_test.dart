import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/home_page.dart';
import 'package:sapoche/ui/player_sheet.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/player/lyrics_view.dart';
import 'package:sapoche/ui/widgets/mini_player.dart';
import 'package:sapoche/ui/widgets/player_bar.dart';
import 'package:sapoche/ui/widgets/track_menu.dart';

import 'fake_backend.dart';
import 'landscape_test.dart' show resize;
import 'pump_app.dart';

/// Opens the app at [width] x [height] dp with a song playing, on the home page.
Future<FakeBackend> pumpAt(
  WidgetTester tester,
  double width,
  double height,
) async {
  final (backend, _) = await pumpApp(tester, listen: false);
  backend.emit(StateEvent(sampleRoom()));
  backend.emit(
    const PositionEvent(
      PlayerPosition(playing: true, positionMs: 4000, durationMs: 200000),
    ),
  );
  await resize(tester, width, height);
  await tester.pump(const Duration(milliseconds: 600));
  expect(tester.takeException(), isNull);
  return backend;
}

const songA = Track(
  videoId: 'aaaaaaaaaaa',
  title: 'Alpha',
  artist: 'Ann',
  durMs: 200000,
);
const songB = Track(
  videoId: 'bbbbbbbbbbb',
  title: 'Beta',
  artist: 'Ben',
  durMs: 180000,
);

/// The layout as the pages see it: from inside the home screen, where the window and the player beside the pages are known.
ShellLayout layoutOf(WidgetTester tester) =>
    HomeShell.layoutOf(tester.element(find.byType(PlayerSheetScope)));

void main() {
  group('the layout follows the width of the window', () {
    for (final (width, height, layout) in [
      (390.0, 844.0, ShellLayout.bars),
      // A phone on its side keeps its tabs up the side
      (844.0, 390.0, ShellLayout.rail),
      (667.0, 375.0, ShellLayout.rail),
      (599.0, 900.0, ShellLayout.bars),
      (540.0, 360.0, ShellLayout.bars),
      (820.0, 1180.0, ShellLayout.rail),
      // With the player beside the pages a sidebar stays only where the pages keep 560 dp
      (915.0, 412.0, ShellLayout.rail),
      (1024.0, 768.0, ShellLayout.rail),
      (1180.0, 820.0, ShellLayout.rail),
      (1280.0, 800.0, ShellLayout.sidebar),
      (1440.0, 900.0, ShellLayout.sidebar),
      (1920.0, 1080.0, ShellLayout.sidebar),
      // Tall, a window has no player beside the pages and keeps the sidebar it had
      (1180.0, 1500.0, ShellLayout.sidebar),
    ]) {
      testWidgets('${width}x$height is $layout', (tester) async {
        await pumpAt(tester, width, height);
        expect(layoutOf(tester), layout);
        expect(tester.takeException(), isNull);
      });
    }
  });

  // A song tapped in a list replaces the queue: the native side reports it empty, then full, a moment apart
  for (final (width, height) in [(390.0, 844.0), (1280.0, 800.0)]) {
    testWidgets(
      'at ${width}x$height a queue that empties and fills at once keeps the player bar whole',
      (tester) async {
        final backend = await pumpAt(tester, width, height);
        for (var i = 0; i < 3; i++) {
          backend.emit(
            StateEvent(sampleRoom(local: true, songs: 0, phase: 'idle')),
          );
          // One frame apart: the capsule that leaves is still in the tree when the next one comes
          await tester.pump();
          backend.emit(
            StateEvent(sampleRoom(local: true, phase: 'paused', loading: true)),
          );
          await tester.pump();
        }
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull);
        expect(find.text('Song 0'), findsWidgets);
      },
    );
  }

  group('the player beside the pages', () {
    // The pages have what is left of the window: the rail or the sidebar, the card and the gaps round it
    for (final (width, height, dock, gap) in [
      (844.0, 390.0, 337.6, 12.0),
      (915.0, 412.0, 360.0, 12.0),
      (1024.0, 768.0, 360.0, 16.0),
      (1180.0, 820.0, 377.6, 16.0),
      (1280.0, 800.0, 409.6, 12.0),
      (1440.0, 900.0, 440.0, 12.0),
    ]) {
      testWidgets(
        '${width}x$height: the pages have what is left of the window',
        (tester) async {
          await pumpAt(tester, width, height);
          expect(find.byType(NowPlayingPage), findsOneWidget);
          expect(find.byType(MiniPlayer), findsNothing);
          expect(find.byType(PlayerBar), findsNothing);
          // What a page reads of its window is what is left of it, after the card and the space on both sides of it
          final page = tester.element(find.byType(HomePage).first);
          expect(
            MediaQuery.sizeOf(page).width,
            closeTo(width - dock - 2 * gap, 1),
          );
          expect(MediaQuery.sizeOf(page).height, height);
          // And what is decided for the window is not changed by it
          expect(HomeShell.windowOf(page), Size(width, height));
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final (width, height) in [
      (390.0, 844.0),
      (640.0, 360.0),
      (1180.0, 1500.0),
    ]) {
      testWidgets('${width}x$height: not beside the pages', (tester) async {
        await pumpAt(tester, width, height);
        expect(find.byType(NowPlayingPage), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('with no song there is none, and the pages have the window', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.emit(const StateEvent(RoomSnapshot()));
      await resize(tester, 1280, 800);
      expect(find.byType(NowPlayingPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the first song brings it, and the last one gone takes it away',
      (tester) async {
        final (backend, _) = await pumpApp(tester, listen: false);
        backend.emit(const StateEvent(RoomSnapshot()));
        await resize(tester, 1280, 800);
        backend.emit(StateEvent(sampleRoom()));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(NowPlayingPage), findsOneWidget);
        backend.emit(const StateEvent(RoomSnapshot()));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(NowPlayingPage), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('Back goes back in the pages, not in the player', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      await tester.tap(find.byTooltip(S.lyrics));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LyricsView), findsOneWidget);
      // The panel is the player's own: Back leaves it open
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LyricsView), findsOneWidget);
      expect(find.byType(NowPlayingPage), findsOneWidget);
    });

    testWidgets('Escape does not close it', (tester) async {
      await pumpAt(tester, 1280, 800);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(NowPlayingPage), findsOneWidget);
    });
  });

  group('beside a rail', () {
    testWidgets('the tabs are in a column on the left and open pages', (
      tester,
    ) async {
      await pumpAt(tester, 820, 1180);
      final home = tester.getRect(find.text(S.tabHome));
      final listen = tester.getRect(find.text(S.tabRoom));
      expect(home.left, lessThan(100));
      expect(listen.top, greaterThan(home.top));
      expect(find.byType(MiniPlayer), findsOneWidget);
      await tester.tap(find.text(S.tabRoom));
      await tester.pumpAndSettle();
      expect(find.text('Song 0'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the mini player floats clear of the rail, within the screen', (
      tester,
    ) async {
      await pumpAt(tester, 820, 1180);
      final mini = tester.getRect(find.byType(MiniPlayer));
      expect(mini.left, greaterThan(100));
      expect(mini.right, lessThanOrEqualTo(820));
      expect(mini.bottom, lessThanOrEqualTo(1180));
      expect(mini.width, lessThanOrEqualTo(520));
    });
  });

  // A window that is taller than it is wide has no player beside the pages, so the bar runs along the bottom
  group('beside a sidebar', () {
    testWidgets('has the search field, the tabs and the playlists', (
      tester,
    ) async {
      await pumpAt(tester, 1400, 1500);
      expect(find.text(S.tabSearch), findsWidgets);
      expect(find.text(S.tabLibrary), findsWidgets);
      expect(find.text(S.likedSongs), findsOneWidget);
      expect(find.text(S.downloadedSongs), findsOneWidget);
      expect(find.byType(PlayerBar), findsOneWidget);
      expect(find.byType(MiniPlayer), findsNothing);
    });

    testWidgets('a liked-songs row opens that list of the library', (
      tester,
    ) async {
      await pumpAt(tester, 1400, 1500);
      await tester.tap(find.text(S.likedSongs));
      await tester.pumpAndSettle();
      // Its title, and the row of the sidebar that opened it
      expect(find.text(S.likedSongs), findsNWidgets(2));
      expect(find.byTooltip(S.downloadAll), findsNothing);
    });

    testWidgets('the music on the phone has a row, which opens its list', (
      tester,
    ) async {
      await pumpAt(tester, 1400, 1500);
      expect(find.text(S.localMusic), findsOneWidget);
      await tester.tap(find.text(S.localMusic));
      await tester.pumpAndSettle();
      // The page that opened, and the row of the sidebar
      expect(find.text(S.localMusic), findsNWidgets(2));
    });

    testWidgets('the player bar runs along the bottom, right of the sidebar', (
      tester,
    ) async {
      await pumpAt(tester, 1400, 1500);
      final bar = tester.getRect(find.byType(PlayerBar));
      expect(bar.left, greaterThan(250));
      expect(bar.right, lessThanOrEqualTo(1400));
      expect(bar.bottom, lessThanOrEqualTo(1500));
      expect(bar.height, PlayerBar.height);
    });

    testWidgets('the bar opens the player, and its lyrics button the lyrics', (
      tester,
    ) async {
      await pumpAt(tester, 1400, 1500);
      await tester.tap(find.byTooltip(S.lyrics));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(LyricsView), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the bar opens the player on the cover', (
      tester,
    ) async {
      await pumpAt(tester, 1400, 1500);
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Song 0'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(LyricsView), findsNothing);
      expect(find.byType(NowPlayingPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Escape closes the player', (tester) async {
      await pumpAt(tester, 1400, 1500);
      await tester.tap(
        find.descendant(
          of: find.byType(PlayerBar),
          matching: find.text('Song 0'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.byType(NowPlayingPage), findsNothing);
    });

    testWidgets('settings show a topic beside the list', (tester) async {
      await pumpAt(tester, 1400, 1500);
      // Beside a sidebar there is no gear at the top of Home: Settings is a row of the sidebar
      expect(find.byTooltip(S.settingsTitle), findsNothing);
      await tester.tap(find.text(S.settingsTitle).last);
      await tester.pumpAndSettle();
      // The list, and the topic that is open beside it
      expect(find.byKey(const ValueKey('settings-appearance')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-system')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('settings-language')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('language-vi')), findsOneWidget);
      expect(find.byKey(const ValueKey('theme-system')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('keys', () {
    testWidgets('Space plays or pauses', (tester) async {
      final backend = await pumpAt(tester, 1280, 800);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(backend.calls, contains('pause'));
    });

    testWidgets('the slash key opens Search with the cursor in the field', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.focusNode.hasFocus, isTrue);
    });
  });

  group('a mouse and a remote', () {
    testWidgets('a right click on a song opens its menu', (tester) async {
      final (backend, _) = await pumpApp(tester, listen: false);
      backend.likedSongs = [songA, songB];
      backend.emit(const StateEvent(RoomSnapshot()));
      await resize(tester, 1280, 800);
      await tester.tap(find.text(S.likedSongs));
      await tester.pumpAndSettle();
      backend.emit(const LibraryEvent());
      await tester.pumpAndSettle();
      // The sidebar row and the list's own title both read this; the list's rows are what the menu is for
      expect(find.byType(TrackMenu), findsWidgets);
      await tester.tap(find.text('Alpha'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text(S.playNext), findsOneWidget);
      expect(find.text(S.addToQueue), findsOneWidget);
    });

    testWidgets('the arrows of a remote move the focus from row to row', (
      tester,
    ) async {
      await pumpAt(tester, 1280, 800);
      // Tab goes through the buttons at the top of the page (the Room chip, the gear), then to the sidebar's first row;
      // the arrows then walk down its column
      for (var i = 0; i < 6; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if ((FocusManager.instance.primaryFocus?.rect.left ?? 999) < 300) break;
      }
      expect(FocusManager.instance.primaryFocus?.rect.left, lessThan(300));
      final seen = <FocusNode?>{FocusManager.instance.primaryFocus};
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        seen.add(FocusManager.instance.primaryFocus);
      }
      // The sidebar's rows are in a column: the arrows go down it, one row at a time
      expect(seen.whereType<FocusNode>().length, greaterThan(1));
      expect(tester.takeException(), isNull);
    });
  });

  group('the pages in a big window', () {
    testWidgets('1920x1080: every tab opens without an overflow', (
      tester,
    ) async {
      await pumpAt(tester, 1920, 1080);
      for (final tab in [S.tabLibrary, S.tabRoom, S.tabHome]) {
        await tester.tap(find.text(tab).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });

    testWidgets('home keeps to a readable width in the middle', (tester) async {
      await pumpAt(tester, 1920, 2000);
      await tester.tap(find.text(S.tabHome).first);
      await tester.pumpAndSettle();
      final title = tester.getRect(
        find.text(S.goodMorning).evaluate().isEmpty
            ? find.text(S.goodAfternoon).evaluate().isEmpty
                  ? find.text(S.goodEvening)
                  : find.text(S.goodAfternoon)
            : find.text(S.goodMorning),
      );
      // The page is 1180 wide in the middle of what is left of the sidebar: its title is not at the sidebar's edge
      expect(title.left, greaterThan(300));
    });
  });
}
