import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/home_shell.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/player/lyrics_view.dart';
import 'package:sapoche/ui/player/up_next_view.dart';
import 'package:sapoche/ui/player/video_controls.dart' show VideoFullScreen;
import 'package:sapoche/ui/player_sheet.dart';
import 'package:sapoche/ui/widgets/artwork.dart';
import 'package:sapoche/ui/widgets/like_button.dart';
import 'package:sapoche/ui/widgets/marquee_text.dart';
import 'package:sapoche/ui/widgets/mini_player.dart';
import 'package:sapoche/ui/widgets/player_bar.dart';
import 'package:sapoche/ui/widgets/playback_bar.dart';
import 'package:sapoche/ui/widgets/transport.dart';
import 'package:sapoche/ui/widgets/video_view.dart';
import 'package:sapoche/ui/widgets/volume_bar.dart';

import 'fake_backend.dart';
import 'player_panels_test.dart' show openPanel, openPlayer;
import 'pump_app.dart';

/// Turns the window to [width] x [height] dp, as the phone is turned or another one is held.
Future<void> resize(WidgetTester tester, double width, double height) async {
  tester.view.physicalSize = Size(width * 2, height * 2);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Rect inside(WidgetTester tester, double width, double height, Finder finder) {
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '$finder, left');
  expect(rect.top, greaterThanOrEqualTo(-0.5), reason: '$finder, top');
  expect(rect.right, lessThanOrEqualTo(width + 0.5), reason: '$finder, right');
  expect(
    rect.bottom,
    lessThanOrEqualTo(height + 0.5),
    reason: '$finder, bottom',
  );
  return rect;
}

void main() {
  group('the player beside the pages', () {
    // A phone on its side, then a tablet and a computer: the player is a card at the right, as tall as the rail at the left
    for (final (width, height, dock) in [
      (844.0, 390.0, 337.6),
      (915.0, 412.0, 360.0),
      (1024.0, 768.0, 360.0),
      (1180.0, 820.0, 377.6),
      (1280.0, 800.0, 409.6),
      (1440.0, 900.0, 440.0),
    ]) {
      testWidgets(
        '${width}x$height: a card of $dock at the right, nothing leaves it',
        (tester) async {
          await openPlayer(tester, snapshot: sampleRoom());
          await resize(tester, width, height);
          expect(tester.takeException(), isNull);
          final card = tester.getRect(find.byType(NowPlayingPage));
          expect(card.width, closeTo(dock, 0.5));
          expect(card.right, lessThan(width));
          expect(card.right, greaterThan(width - 24));
          expect(card.top, greaterThanOrEqualTo(0));
          expect(card.bottom, lessThanOrEqualTo(height));
          // There is no bar or mini player: the player is already there, and it has no way out
          expect(find.byType(MiniPlayer), findsNothing);
          expect(find.byType(PlayerBar), findsNothing);
          expect(find.byTooltip(S.close), findsNothing);
          for (final finder in [
            find.byType(PlaybackBar),
            find.byTooltip(S.lyrics),
            find.byTooltip(S.upNext),
            find.byType(CoverSlot),
          ]) {
            final r = tester.getRect(finder);
            expect(card.contains(r.topLeft), isTrue, reason: '$finder');
            expect(
              r.right,
              lessThanOrEqualTo(card.right + 0.5),
              reason: '$finder',
            );
            expect(
              r.bottom,
              lessThanOrEqualTo(card.bottom + 0.5),
              reason: '$finder',
            );
          }
          final cover = tester.getRect(find.byType(CoverSlot));
          final bar = tester.getRect(find.byType(PlaybackBar));
          expect(
            cover.bottom,
            lessThan(bar.top + 1),
            reason: 'cover above the seek bar',
          );
          // The pages have what is left of the window
          final page = tester.getRect(find.byType(Navigator).first);
          expect(page.right, lessThanOrEqualTo(width));
        },
      );
    }

    testWidgets(
      'on a phone the cover is not smaller than the player leaves it',
      (tester) async {
        await openPlayer(tester, snapshot: sampleRoom());
        await resize(tester, 844, 390);
        final cover = tester.getRect(find.byType(CoverSlot));
        expect(cover.height, greaterThan(150));
        // No volume and no row of icons of their own: the small player has the buttons of a phone on its side
        expect(find.byType(VolumeBar), findsNothing);
      },
    );

    testWidgets(
      'upright the player is the sheet again, and the same song is on it',
      (tester) async {
        await openPlayer(tester, snapshot: sampleRoom());
        await resize(tester, 844, 390);
        await resize(tester, 390, 844);
        expect(tester.takeException(), isNull);
        // The sheet fills the screen again
        expect(
          tester.getRect(find.byType(NowPlayingPage)),
          const Rect.fromLTWH(0, 0, 390, 844),
        );
      },
    );

    testWidgets(
      'a window too narrow for it keeps the sheet, in the small player',
      (tester) async {
        await openPlayer(tester, snapshot: sampleRoom());
        await resize(tester, 667, 375);
        expect(tester.takeException(), isNull);
        final cover = inside(tester, 667, 375, find.byType(CoverSlot));
        final bar = inside(tester, 667, 375, find.byType(PlaybackBar));
        inside(tester, 667, 375, find.byTooltip(S.lyrics));
        inside(tester, 667, 375, find.byTooltip(S.upNext));
        expect(cover.bottom, lessThan(bar.top + 1));
        expect(find.byType(VolumeBar), findsNothing);
      },
    );

    testWidgets(
      'the lyrics take the place of the cover, under a line with the song',
      (tester) async {
        await openPlayer(tester, snapshot: sampleRoom());
        await resize(tester, 844, 390);
        await openPanel(tester, S.lyrics);
        expect(tester.takeException(), isNull);
        expect(find.byType(LyricsView), findsOneWidget);
        // The seek bar and the buttons stay where they are; the cover is the small one in the line of the song
        expect(find.byType(PlaybackBar), findsOneWidget);
        expect(find.byType(CoverSlot), findsNothing);
        expect(
          find.descendant(
            of: find.byType(NowPlayingPage),
            matching: find.byType(LikeButton),
          ),
          findsOneWidget,
        );
        // The same button again goes back to the cover
        await openPanel(tester, S.lyrics);
        expect(find.byType(LyricsView), findsNothing);
        expect(find.byType(CoverSlot), findsOneWidget);
      },
    );

    testWidgets('the buttons and the seek bar stay put when a panel opens', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await resize(tester, 844, 390);
      final bar = tester.getRect(find.byType(PlaybackBar));
      final lyrics = tester.getRect(find.byTooltip(S.lyrics));
      final play = tester.getRect(find.byType(PlayPauseButton).last);
      for (final panel in [S.lyrics, S.upNext]) {
        await openPanel(tester, panel);
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.byType(PlaybackBar)), bar, reason: panel);
        expect(tester.getRect(find.byTooltip(S.lyrics)), lyrics, reason: panel);
        expect(
          tester.getRect(find.byType(PlayPauseButton).last),
          play,
          reason: panel,
        );
        await openPanel(tester, panel);
      }
    });

    testWidgets('turning the phone keeps the panel that is open', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom());
      await openPanel(tester, S.upNext);
      await resize(tester, 844, 390);
      expect(tester.takeException(), isNull);
      expect(find.byType(UpNextView), findsOneWidget);
      await resize(tester, 390, 844);
      expect(tester.takeException(), isNull);
      expect(find.byType(UpNextView), findsOneWidget);
    });

    testWidgets('a video is across the card, over the seek bar', (
      tester,
    ) async {
      await openPlayer(tester, snapshot: sampleRoom(video: true));
      await resize(tester, 844, 390);
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.byType(NowPlayingPage));
      final bar = inside(tester, 844, 390, find.byType(PlaybackBar));
      final picture = tester.getRect(find.byType(VideoView));
      expect(card.contains(picture.topLeft), isTrue);
      expect(picture.bottom, lessThan(bar.top + 1));
      expect(picture.width, greaterThan(200));
    });

    testWidgets(
      'a song with no picture to be had shows its cover, without a spinner',
      (tester) async {
        final backend = await openPlayer(
          tester,
          snapshot: sampleRoom(video: true),
        );
        final spinner = find.descendant(
          of: find.byType(VideoView),
          matching: find.byType(CircularProgressIndicator),
        );
        expect(spinner, findsOneWidget, reason: 'waiting for the picture');
        backend.emit(
          const PositionEvent(PlayerPosition(playing: true, noPicture: true)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        expect(spinner, findsNothing);
        expect(
          find.descendant(
            of: find.byType(VideoView),
            matching: find.byType(Artwork),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('turning the phone keeps the picture coming', (tester) async {
      final backend = await openPlayer(
        tester,
        snapshot: sampleRoom(video: true),
      );
      String lastVisible() =>
          backend.calls.lastWhere((c) => c.startsWith('videoVisible'));
      expect(lastVisible(), 'videoVisible true');
      // The new layout's picture comes before the old one's goes; the old one leaving must not hide the picture
      await resize(tester, 844, 390);
      expect(lastVisible(), 'videoVisible true');
      await resize(tester, 390, 844);
      expect(lastVisible(), 'videoVisible true');

      // A control centre pulled down keeps it; the app going to the background stops it, and coming back brings it
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(lastVisible(), 'videoVisible true');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(lastVisible(), 'videoVisible false');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(lastVisible(), 'videoVisible true');
    });
  });

  group('the mini player', () {
    testWidgets('scrolls a long title and artist instead of cutting them', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      // Too narrow for the player to stand beside the pages: the mini player is there
      await resize(tester, 660, 360);
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.byType(MarqueeText),
        ),
        findsNWidgets(2),
      );
    });
  });

  group('the bars on their side', () {
    testWidgets(
      'are a rail of icons up the left, and the mini player floats alone',
      (tester) async {
        final (backend, _) = await pumpApp(tester);
        backend.emit(StateEvent(sampleRoom()));
        // Too narrow for the player to stand beside the pages: the mini player is there
        await resize(tester, 660, 360);
        await tester.pump(const Duration(milliseconds: 700));
        expect(tester.takeException(), isNull);
        final context = tester.element(find.byType(HomeShell));
        expect(HomeShell.layoutOf(context), ShellLayout.rail);
        expect(HomeShell.compactOf(context), isTrue);
        // The four places and Settings, named by their tooltips, in a column on the left that fits the window
        final rail = [
          for (final name in [S.tabHome, S.tabSearch, S.tabLibrary, S.tabRoom])
            tester.getRect(find.byTooltip(name)),
        ];
        for (final r in rail) {
          expect(r.right, lessThan(90));
          expect(r.bottom, lessThan(360));
        }
        expect(rail.first.top, lessThan(rail.last.top));
        expect(
          tester.getRect(find.byTooltip(S.settingsTitle)).bottom,
          lessThan(360),
        );
        // The mini player is beside the rail, not under it, and no wider than a phone's was long
        final mini = tester.getRect(find.byType(MiniPlayer));
        expect(mini.left, greaterThan(rail.first.right));
        expect(mini.width, lessThanOrEqualTo(400));
        expect(mini.bottom, lessThan(360));
      },
    );

    for (final size in [const Size(390, 844), const Size(660, 360)]) {
      testWidgets(
        'the play and next buttons of the mini player are alike and level at $size',
        (tester) async {
          final (backend, _) = await pumpApp(tester);
          tester.view.physicalSize = size * 2;
          backend.emit(StateEvent(sampleRoom()));
          await tester.pump(const Duration(milliseconds: 700));
          await tester.pump(const Duration(milliseconds: 700));
          final mini = find.byType(MiniPlayer);
          final play = tester.getRect(
            find.descendant(of: mini, matching: find.byType(PlayPauseButton)),
          );
          final next = tester.getRect(
            find.descendant(of: mini, matching: find.byType(SkipButton)),
          );
          expect(next.center.dy, closeTo(play.center.dy, 0.5), reason: '$size');
          expect(next.size, play.size, reason: '$size');
          final glyphs = [
            for (final button in [PlayPauseButton, SkipButton])
              tester.getSize(
                find.descendant(
                  of: find.descendant(of: mini, matching: find.byType(button)),
                  matching: find.byType(Icon),
                ),
              ),
          ];
          expect(glyphs.first, glyphs.last, reason: '$size');
        },
      );
    }

    testWidgets('are lower, and lists clear them', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      // Too narrow for the player to stand beside the pages: the mini player is there
      await resize(tester, 660, 360);
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(MiniPlayer)).height, 40);
      final context = tester.element(find.byType(HomeShell));
      expect(HomeShell.bottomInsetOf(context), lessThan(176));
      // Nothing of the bars is out of the window
      expect(tester.getRect(find.byType(MiniPlayer)).bottom, lessThan(360));
      // And upright they are what they were
      await resize(tester, 390, 844);
      expect(tester.getSize(find.byType(MiniPlayer)).height, 46);
    });
  });

  group('the status bar', () {
    testWidgets(
      'is hidden while a phone is on its side, and comes back upright',
      (tester) async {
        // A test before this one may have left a full screen open: its flag is a global
        VideoFullScreen.open.value = false;
        final calls = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) {
              calls.add('${call.method} ${call.arguments}');
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await pumpApp(tester);
        await tester.pump();
        expect(
          calls.where((c) => c.contains('bottom')),
          isEmpty,
          reason: 'upright it is as it was',
        );
        await resize(tester, 844, 390);
        // Only the top is hidden: the navigation bar of the system stays
        expect(calls.last, contains('SystemUiOverlay.bottom'));
        expect(calls.last, isNot(contains('top')));
        await resize(tester, 390, 844);
        expect(calls.last, contains('SystemUiMode.edgeToEdge'));
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );

    testWidgets('a tablet, which has the height, keeps it', (tester) async {
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) {
            calls.add('${call.method} ${call.arguments}');
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpApp(tester);
      await resize(tester, 1180, 820);
      expect(calls.where((c) => c.contains('bottom')), isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  group('the version', () {
    testWidgets('is in small print at the foot of the settings', (
      tester,
    ) async {
      PackageInfo.setMockInitialValues(
        appName: 'Sapoche',
        packageName: 'app.sapoche',
        version: '1.4.1',
        buildNumber: '12',
        buildSignature: '',
      );
      await pumpApp(tester);
      await openSettingsList(tester);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('settings-version')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Sapoche 1.4.1 (12)'), findsOneWidget);
    });
  });
}
