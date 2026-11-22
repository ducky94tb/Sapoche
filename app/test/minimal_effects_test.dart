import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/calm.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/player/apple_music_player.dart';
import 'package:sapoche/ui/player_sheet.dart';
import 'package:sapoche/ui/widgets/motion.dart';

import 'fake_backend.dart';
import 'player_styles_test.dart' show openStyled;
import 'pump_app.dart';

/// The Minimal level of effects for phones too weak for the rest (`docs/plans/2026-11-22-minimal-effects.md`): pages and
/// the player come at once, nothing is blurred, nothing casts a shadow. What costs a frame is counted, not timed, so
/// that the test says the same on any machine.
void main() {
  tearDown(() => Calm.chosen = null);

  const box = ValueKey('box');

  /// A new level reaches the screen through the theme, which is animated: a frame to start it, then time to end it.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// How many layers of each kind the screen is made of.
  Map<Type, int> layers(WidgetTester tester) {
    final counts = <Type, int>{};
    void walk(Layer layer) {
      counts[layer.runtimeType] = (counts[layer.runtimeType] ?? 0) + 1;
      if (layer is ContainerLayer) {
        for (
          var child = layer.firstChild;
          child != null;
          child = child.nextSibling
        ) {
          walk(child);
        }
      }
    }

    walk(tester.binding.renderViews.first.debugLayer!);
    return counts;
  }

  int blurs(WidgetTester tester) {
    final counts = layers(tester);
    return (counts[BackdropFilterLayer] ?? 0) + (counts[ImageFilterLayer] ?? 0);
  }

  Widget twoPages(EffectsLevel level, {bool instant = true}) => MaterialApp(
    theme: buildTheme(
      Palette.forAccent(null, Brightness.light),
      effects: level,
      instantTransitions: instant,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('second')),
            ),
          ),
          child: const Text('first'),
        ),
      ),
    ),
  );

  group('pages', () {
    testWidgets('come at once, the one before gone with them', (tester) async {
      await tester.pumpWidget(twoPages(EffectsLevel.minimal));
      await tester.tap(find.text('first'));
      await tester.pump();
      await tester.pump();
      expect(find.text('second'), findsOneWidget);
      expect(
        find.text('first'),
        findsNothing,
        reason: 'two pages are not drawn on top of each other',
      );
    });

    testWidgets('slide in, both drawn, otherwise', (tester) async {
      await tester.pumpWidget(twoPages(EffectsLevel.full, instant: false));
      await tester.tap(find.text('first'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('second'), findsOneWidget);
      expect(find.text('first'), findsOneWidget);
    });
  });

  group('the player', () {
    testWidgets('opens and closes at once at the minimum', (tester) async {
      late PlayerSheetController sheet;
      await tester.pumpWidget(
        _Host(
          builder: (vsync) =>
              sheet = PlayerSheetController(vsync, isStill: () => true),
        ),
      );
      sheet.open();
      await tester.pump();
      expect(sheet.position.value, 1);
      sheet.close();
      await tester.pump();
      expect(sheet.position.value, 0);
      sheet.dispose();
    });

    testWidgets('is not pulled out of a finger that has taken hold', (
      tester,
    ) async {
      late PlayerSheetController sheet;
      await tester.pumpWidget(
        _Host(
          builder: (vsync) =>
              sheet = PlayerSheetController(vsync, isStill: () => true),
        ),
      );
      sheet.open();
      await tester.pump();
      sheet.close();
      sheet.beginDrag();
      await tester.pump();
      expect(
        sheet.position.value,
        1,
        reason: 'the jump to closed was waiting for the end of the frame',
      );
      sheet.dispose();
    });

    testWidgets('glides otherwise', (tester) async {
      late PlayerSheetController sheet;
      await tester.pumpWidget(
        _Host(
          builder: (vsync) =>
              sheet = PlayerSheetController(vsync, isStill: () => false),
        ),
      );
      sheet.open();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(sheet.position.value, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      sheet.dispose();
    });

    testWidgets('stays open when the level is changed under it', (
      tester,
    ) async {
      await openStyled(tester, PlayerStyle.appleMusic, mode: ThemeMode.dark);
      expect(find.byType(AppleMusicPlayer), findsOneWidget);
      Calm.chosen = EffectsLevel.minimal;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byType(AppleMusicPlayer),
        findsOneWidget,
        reason: 'the screen is not built again for a setting',
      );
    });
  });

  group('the screen is made of fewer layers', () {
    testWidgets('on the home page: no glass to blur what is behind it', (
      tester,
    ) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(StateEvent(sampleRoom()));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        blurs(tester),
        greaterThan(0),
        reason: 'the bars are glass at full effects',
      );
      Calm.chosen = EffectsLevel.minimal;
      await tester.pump(
        const Duration(milliseconds: 400),
      ); // the theme is animated
      expect(blurs(tester), 0);
    });

    testWidgets(
      'in the full cover player: no blurred strip under the status bar',
      (tester) async {
        tester.view.padding = const FakeViewPadding(top: 120);
        tester.view.viewPadding = const FakeViewPadding(top: 120);
        await openStyled(tester, PlayerStyle.appleMusic, mode: ThemeMode.dark);
        Calm.chosen = EffectsLevel.light;
        await settle(tester);
        expect(blurs(tester), greaterThan(0), reason: 'Light keeps it');
        Calm.chosen = EffectsLevel.minimal;
        await settle(tester);
        expect(blurs(tester), 0);
      },
    );
  });

  group('the minimum', () {
    testWidgets('casts no shadow', (tester) async {
      late BuildContext flat, full;
      Widget under(EffectsLevel level, void Function(BuildContext) take) =>
          Theme(
            data: buildTheme(
              Palette.forAccent(null, Brightness.light),
              effects: level,
            ),
            child: Builder(
              builder: (context) {
                take(context);
                return const SizedBox();
              },
            ),
          );
      await tester.pumpWidget(
        Column(
          textDirection: TextDirection.ltr,
          children: [
            under(EffectsLevel.minimal, (c) => flat = c),
            under(EffectsLevel.full, (c) => full = c),
          ],
        ),
      );
      const shadow = [BoxShadow(blurRadius: 8)];
      expect(flat.shadowsOf(shadow), isEmpty);
      expect(full.shadowsOf(shadow), shadow);
    });

    testWidgets('a size that changes does so at once, and without a fault', (
      tester,
    ) async {
      Widget host(double height) => MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: MotionSize(
              milliseconds: 200,
              alignment: Alignment.topCenter,
              child: SizedBox(key: box, width: 50, height: height),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(40));
      await tester.pumpWidget(host(90));
      expect(tester.getSize(find.byKey(box)).height, 90);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a size that changes grows over time at full effects', (
      tester,
    ) async {
      Widget host(double height) => MediaQuery(
        data: const MediaQueryData(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: MotionSize(
              milliseconds: 200,
              alignment: Alignment.topCenter,
              child: SizedBox(key: box, width: 50, height: height),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host(40));
      await tester.pumpWidget(host(90));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.getSize(find.byType(MotionSize)).height,
        inExclusiveRange(40, 90),
      );
      await tester.pumpAndSettle();
    });
  });
}

/// Gives a controller something to tick with.
class _Host extends StatefulWidget {
  const _Host({required this.builder});

  final void Function(TickerProvider vsync) builder;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  @override
  void initState() {
    super.initState();
    widget.builder(this);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
