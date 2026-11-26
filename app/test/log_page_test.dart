import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/strings.dart';

import 'fake_backend.dart';
import 'pump_app.dart';
import 'shots/shot_data.dart';

/// The log page: from Settings, what it says at the top, how the lines are cut, filtered and found, and what a touch does.
void main() {
  Future<FakeBackend> openLog(
    WidgetTester tester, {
    List<String>? lines,
  }) async {
    final (backend, _) = await pumpApp(
      tester,
      listen: false,
      prepare: (b) {
        b.logLines = lines ?? shotLog();
        b.logInfoLines = [
          'app: 1.54.1+117',
          'platform: Android 14',
          'device: SHARP SH-51G',
        ];
      },
    );
    backend.emit(const StateEvent(RoomSnapshot()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(S.settingsTitle));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('settings-advanced')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const ValueKey('settings-advanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-log')));
    await tester.pumpAndSettle();
    return backend;
  }

  testWidgets(
    'the tiles count the errors and the warnings of the last run, and the clean sentence stays away',
    (tester) async {
      await openLog(tester);
      expect(find.byKey(const ValueKey('log-summary')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('log-chip-E')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      expect(find.text(S.logPreviousFailed), findsOneWidget);
    },
  );

  /// A log of [count] main lines, one a second, with an error at line 5.
  List<String> longLog(int count) => [
    '11-25 10:00:00.000 K [log] ---- process started ---- 1.57.1+121',
    for (var i = 0; i < count; i++)
      '11-25 10:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}.500 '
          '${i == 5 ? 'E [player] player error at step $i' : 'K [app] step $i'}',
  ];

  testWidgets(
    'a long log opens on its newest line without laying out the rest, and an old error is still reached',
    (tester) async {
      await openLog(tester, lines: longLog(400));
      // Laid out from its end: the newest line is there and the first ones were never built
      expect(find.textContaining('step 399', findRichText: true), findsOneWidget);
      expect(find.textContaining('step 10', findRichText: true), findsNothing);
      await tester.tap(find.byKey(const ValueKey('log-error-next')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('player error at step 5', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'new lines leave the older ones being read where they are, and "New lines" brings them',
    (tester) async {
      final backend = await openLog(tester, lines: longLog(400));
      final reading = find.textContaining('step 300', findRichText: true);
      await tester.dragUntilVisible(
        reading,
        find.byType(ListView).last,
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();
      expect(reading, findsOneWidget);
      final before = tester.getTopLeft(reading);
      backend.logLines = [
        ...backend.logLines,
        '11-25 10:07:00.000 K [app] a new step',
      ];
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(reading), before);
      expect(find.textContaining('a new step', findRichText: true), findsNothing);
      await tester.tap(find.byKey(const ValueKey('log-new-lines')));
      await tester.pumpAndSettle();
      expect(find.textContaining('a new step', findRichText: true), findsOneWidget);
    },
  );

  testWidgets('a log with nothing wrong says so', (tester) async {
    await openLog(
      tester,
      lines: [
        '11-23 08:00:00.000 K [log] ---- process started ---- 1.0.0+1',
        '11-23 08:00:01.000 I [play] hello',
      ],
    );
    expect(find.text(S.logClean), findsOneWidget);
    expect(find.text(S.logPreviousFailed), findsNothing);
  });

  testWidgets(
    'the main mode shows warnings and says how many lines it hides; All shows the quiet ones',
    (tester) async {
      await openLog(tester);
      expect(
        find.textContaining('weak network', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('network is good again', findRichText: true),
        findsNothing,
      );
      expect(find.textContaining(S.logHidden(1)), findsWidgets);
      await tester.tap(find.text(S.logModeAll));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('network is good again', findRichText: true),
        findsOneWidget,
      );
    },
  );

  testWidgets('touching the count of errors keeps the errors alone', (
    tester,
  ) async {
    await openLog(tester);
    await tester.tap(find.byKey(const ValueKey('log-chip-E')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('player error', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('weak network', findRichText: true),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('log-chip-E')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('weak network', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('one touch on "next error" brings the newest error into view', (
    tester,
  ) async {
    await openLog(tester);
    await tester.tap(find.byKey(const ValueKey('log-error-next')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('player error', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a group keeps its lines (and the marks)', (tester) async {
    await openLog(tester);
    await tester.tap(find.text(S.logModeAll));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('log-group-play')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('loaded Em Của', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('up to date', findRichText: true), findsNothing);
  });

  testWidgets('the search counts what it finds and lights it', (tester) async {
    await openLog(tester);
    await tester.tap(find.byKey(const ValueKey('log-search-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('log-search')), 'stalled');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('stalled for', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('weak network', findRichText: true),
      findsNothing,
    );
    expect(find.text('0/1'), findsOneWidget);
  });

  testWidgets('quiet lines of one tag are one row that opens', (tester) async {
    await openLog(tester);
    await tester.tap(find.text(S.logModeDetail));
    await tester.pumpAndSettle();
    final fold = find.textContaining('lines [sync]');
    expect(fold, findsWidgets);
    expect(find.textContaining('drift=', findRichText: true), findsNothing);
    await tester.tap(fold.last);
    await tester.pumpAndSettle();
    expect(find.textContaining('drift=', findRichText: true), findsWidgets);
  });

  testWidgets(
    'a line opens in full, with the lines around it, and can be copied',
    (tester) async {
      await openLog(tester);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
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
      await tester.tap(
        find.textContaining('player error', findRichText: true).first,
      );
      await tester.pumpAndSettle();
      expect(find.text(S.logAround), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('log-copy-line')));
      await tester.pumpAndSettle();
      expect(copied, contains('E [player] player error, recovering (#1)'));
    },
  );

  testWidgets('the stack of a crash is one frame to a line', (tester) async {
    await openLog(tester);
    await tester.tap(find.byKey(const ValueKey('log-previous-run')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.textContaining('uncaught on main', findRichText: true).first,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('app.sapoche.PlaybackService.onUpdate:412'),
      findsOneWidget,
    );
    expect(find.text('app.sapoche.SapocheBridge.handle:871'), findsOneWidget);
  });

  testWidgets('a mark takes a note and leaves a line the page shows', (
    tester,
  ) async {
    final backend = await openLog(tester);
    await tester.tap(find.byKey(const ValueKey('log-mark')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('log-mark-note')),
      'sound broke up',
    );
    await tester.tap(find.widgetWithText(FilledButton, S.logMark).last);
    await tester.pumpAndSettle();
    expect(backend.marks, ['sound broke up']);
    expect(
      find.textContaining('sound broke up', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets(
    'clearing asks first, then empties the log and says there is nothing',
    (tester) async {
      final backend = await openLog(tester);
      await tester.tap(find.byKey(const ValueKey('log-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.logClear));
      await tester.pumpAndSettle();
      expect(find.text(S.logClearQuestion), findsOneWidget);
      expect(backend.logLines, isNotEmpty);
      await tester.tap(find.widgetWithText(FilledButton, S.logClear));
      await tester.pumpAndSettle();
      expect(backend.logLines, isEmpty);
      expect(find.text(S.logEmpty), findsOneWidget);
    },
  );

  testWidgets('"Show all" in the empty main view opens the quiet lines', (
    tester,
  ) async {
    await openLog(
      tester,
      lines: ['11-23 08:00:00.000 I [play] only a quiet line'],
    );
    expect(find.text(S.logEmpty), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('log-show-all')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('only a quiet line', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets(
    '"Copy short version" puts the head and the main lines on the clipboard',
    (tester) async {
      await openLog(tester);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
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
      await tester.tap(find.byKey(const ValueKey('log-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(S.logCopyShort));
      await tester.pumpAndSettle();
      expect(copied, contains('app: 1.54.1+117'));
      expect(copied, contains('SHARP SH-51G'));
      expect(copied, contains('closed: 1006'));
    },
  );

  testWidgets('a key in a link never reaches the page or the export', (
    tester,
  ) async {
    final backend = await openLog(
      tester,
      lines: [
        '11-23 08:00:00.000 K [log] ---- process started ---- 1',
        '11-23 08:00:01.000 W [room] failed https://x.example/join?room=ABC&key=SECRETVALUE123 now',
      ],
    );
    await tester.tap(find.text(S.logModeAll));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('SECRETVALUE123', findRichText: true),
      findsNothing,
    );
    expect(find.textContaining('key=…', findRichText: true), findsOneWidget);
    expect(
      backend.logLines.join(),
      contains('SECRETVALUE123'),
      reason: 'the fake kept it: only the page hides it',
    );
  });
}
