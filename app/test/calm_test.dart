import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/app_settings.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/calm.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/widgets/shimmer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pump_app.dart';

void main() {
  tearDown(() {
    Calm.chosen = null;
    Calm.weak = false;
    Calm.warm = false;
  });

  group('Calm', () {
    test('is off for a phone that is cool, strong and left alone', () {
      expect(Calm.on.value, isFalse);
      expect(Calm.light.value, isFalse);
    });

    test('is on while the phone is warm, without being a setting', () {
      Calm.warm = true;
      expect(Calm.on.value, isTrue);
      expect(Calm.light.value, isFalse);
      Calm.warm = false;
      expect(Calm.on.value, isFalse);
    });

    test('is on for a weak phone until the person says otherwise', () {
      Calm.weak = true;
      expect(Calm.on.value, isTrue);
      expect(Calm.light.value, isTrue);
      Calm.chosen = EffectsLevel.full;
      expect(Calm.on.value, isFalse);
      expect(Calm.light.value, isFalse);
      Calm.chosen = null;
      expect(Calm.light.value, isTrue);
    });

    test('is on when the person chose it, whatever the phone', () {
      Calm.chosen = EffectsLevel.light;
      expect(Calm.on.value, isTrue);
      Calm.warm = true;
      Calm.chosen = EffectsLevel.full;
      // Still warm: the choice is about the setting, not about the heat
      expect(Calm.on.value, isTrue);
      expect(Calm.light.value, isFalse);
    });

    test(
      'the native side says whether the phone is weak along with the heat',
      () {
        final event = const CalmEvent(false, weak: true);
        expect(event.weak, isTrue);
        expect(const CalmEvent(true).weak, isFalse);
      },
    );
  });

  testWidgets('loading rows stand still while the effects are light', (
    tester,
  ) async {
    Calm.chosen = EffectsLevel.light;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Palette.light),
        home: const Scaffold(body: SkeletonList()),
      ),
    );
    // A sweep that goes on for ever would never let this settle
    await tester.pumpAndSettle();
    Calm.chosen = EffectsLevel.full;
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    Calm.chosen = EffectsLevel.light;
    await tester.pump();
    await tester.pumpAndSettle();
  });

  group('the minimal level', () {
    test('is chosen by the person, and heat alone never brings it', () {
      Calm.warm = true;
      expect(Calm.minimal.value, isFalse);
      expect(Calm.level.value, EffectsLevel.full);
      Calm.chosen = EffectsLevel.minimal;
      expect(Calm.minimal.value, isTrue);
      expect(Calm.light.value, isTrue);
      expect(Calm.on.value, isTrue);
    });

    test('a very weak phone starts with it, a choice overrules it', () {
      Calm.veryWeak = true;
      expect(Calm.level.value, EffectsLevel.minimal);
      Calm.chosen = EffectsLevel.light;
      expect(Calm.level.value, EffectsLevel.light);
      expect(Calm.minimal.value, isFalse);
      Calm.chosen = EffectsLevel.full;
      expect(Calm.level.value, EffectsLevel.full);
      expect(Calm.on.value, isFalse);
      Calm.chosen = null;
      expect(Calm.level.value, EffectsLevel.minimal);
      Calm.veryWeak = false;
      expect(Calm.level.value, EffectsLevel.full);
    });

    test('the native side says whether the phone is very weak', () {
      expect(const CalmEvent(false, veryWeak: true).veryWeak, isTrue);
      expect(const CalmEvent(true).veryWeak, isFalse);
    });
  });

  group('the setting', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    tearDown(() => Calm.veryWeak = false);

    test('is remembered, and loaded into Calm', () async {
      var settings = await AppSettings.load();
      expect(settings.effects, isNull);
      settings.effects = EffectsLevel.minimal;
      expect(Calm.level.value, EffectsLevel.minimal);
      settings = await AppSettings.load();
      expect(settings.effects, EffectsLevel.minimal);
      Calm.chosen = null;
      settings = await AppSettings.load();
      expect(Calm.minimal.value, isTrue);
      settings.effects = null;
      expect(Calm.level.value, EffectsLevel.full);
    });

    test('the old Light effects switch keeps what the person chose', () async {
      SharedPreferences.setMockInitialValues({'light_effects': true});
      var settings = await AppSettings.load();
      expect(settings.effects, EffectsLevel.light);
      SharedPreferences.setMockInitialValues({'light_effects': false});
      settings = await AppSettings.load();
      expect(settings.effects, EffectsLevel.full);
      // A level chosen since wins over the old key, and the old key is gone
      settings.effects = EffectsLevel.minimal;
      settings = await AppSettings.load();
      expect(settings.effects, EffectsLevel.minimal);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('light_effects'), isFalse);
    });

    testWidgets('are three rows in Appearance that show what is in force', (
      tester,
    ) async {
      await pumpApp(tester);
      await openTopic(tester, 'appearance');
      bool ticked(EffectsLevel level) => find
          .descendant(
            of: find.byKey(ValueKey('effects-${level.name}')),
            matching: find.byIcon(Icons.check_rounded),
          )
          .evaluate()
          .isNotEmpty;
      expect(ticked(EffectsLevel.full), isTrue);
      expect(ticked(EffectsLevel.minimal), isFalse);
      await tester.ensureVisible(
        find.byKey(const ValueKey('effects-minimal')),
      );
      await tester.tap(find.byKey(const ValueKey('effects-minimal')));
      await tester.pumpAndSettle();
      expect(ticked(EffectsLevel.minimal), isTrue);
      expect(ticked(EffectsLevel.full), isFalse);
      expect(Calm.minimal.value, isTrue);
      await tester.tap(find.byKey(const ValueKey('effects-light')));
      await tester.pumpAndSettle();
      expect(Calm.on.value, isTrue);
      expect(Calm.minimal.value, isFalse);
      await tester.tap(find.byKey(const ValueKey('effects-full')));
      await tester.pumpAndSettle();
      expect(Calm.on.value, isFalse);
    });

    testWidgets('a weak phone starts with Light', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(const CalmEvent(false, weak: true));
      await tester.pumpAndSettle();
      expect(Calm.level.value, EffectsLevel.light);
    });

    testWidgets('a very weak phone starts with Minimal', (tester) async {
      final (backend, _) = await pumpApp(tester);
      backend.emit(const CalmEvent(false, weak: true, veryWeak: true));
      await tester.pumpAndSettle();
      expect(Calm.level.value, EffectsLevel.minimal);
    });
  });
}
