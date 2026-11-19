import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/ui/cover_glow.dart';
import 'package:sapoche/ui/widgets/player_backdrop.dart';

import 'cover_glow_test.dart' show painted, solid;

/// WCAG 2.x contrast of [fg] drawn over [bg] (a see-through [fg] is mixed with it first, as it is on screen).
double contrast(Color fg, Color bg) {
  final top = Color.alphaBlend(fg, bg);
  final a = top.computeLuminance(), b = bg.computeLuminance();
  final hi = a > b ? a : b, lo = a > b ? b : a;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  /// The pictures the full player lays down behind everything: [CoverGlow.render] of covers from black to white and
  /// of every hue at full strength, in each theme. Every pixel is a ground the words and icons can land on.
  Future<List<Color>> grounds({required bool light, bool vivid = false}) async {
    final covers = <ui.Image>[
      for (final rgb in const [
        [0, 0, 0],
        [255, 255, 255],
        [128, 128, 128],
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [255, 255, 0],
        [0, 255, 255],
        [255, 0, 255],
        [255, 128, 0],
        [40, 40, 90],
      ])
        await solid(rgb[0], rgb[1], rgb[2]),
      // A cover of two halves: the glow is made of patches, and a bright one can sit next to a deep one
      await painted((x, y) => x < 24 ? [255, 255, 255] : [0, 0, 120]),
    ];
    final out = <Color>[];
    for (final cover in covers) {
      final glow = await CoverGlow.render(cover, light: light, vivid: vivid);
      final data = (await glow.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      for (var i = 0; i < data.lengthInBytes; i += 4 * 7) {
        final ground = Color.fromARGB(
          255,
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        );
        // The veil over it is at least this much; the page's gradient only makes it stronger
        out.add(
          light ? ground : Color.alphaBlend(PlayerBackdrop.darkestVeil, ground),
        );
      }
    }
    return out;
  }

  // The flat colour of the style of cards, taken from the top of the same picture as the other two: words keep their 4.5:1
  // on it, and on the card of the lyrics, a little deeper (dark theme: white words on the colour with the card at 45%
  // black; light: dark words on it with the card at 6% black)
  for (final light in [true, false]) {
    testWidgets(
      'on the flat colour of the cards, words keep 4.5:1 (${light ? 'light' : 'dark'})',
      (tester) async {
        await tester.runAsync(() async {
          final onCover = (light ? Palette.light : Palette.dark).onCover;
          var worst = double.infinity;
          for (final cover in [
            for (final rgb in const [
              [0, 0, 0],
              [255, 255, 255],
              [128, 128, 128],
              [255, 0, 0],
              [0, 255, 0],
              [0, 0, 255],
              [255, 255, 0],
              [0, 255, 255],
              [255, 0, 255],
              [255, 128, 0],
              [40, 40, 90],
            ])
              await solid(rgb[0], rgb[1], rgb[2]),
            await painted((x, y) => x < 24 ? [255, 255, 255] : [0, 0, 120]),
          ]) {
            final glow = await CoverGlow.render(
              cover,
              light: light,
              vivid: light,
            );
            final ground = await CoverGlow.groundOf(glow, light: light);
            final card = Color.lerp(ground, Colors.black, light ? 0.06 : 0.45)!;
            for (final g in [ground, card]) {
              final c = contrast(onCover.textSecondary, g);
              if (c < worst) worst = c;
            }
          }
          expect(worst, greaterThanOrEqualTo(4.5));
        });
      },
    );
  }

  // The richer light ground of the full cover: dark words keep their 4.5:1 on every one of them too
  testWidgets('on the vivid ground of the full cover, words keep 4.5:1', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final onCover = Palette.light.onCover;
      var worst = double.infinity;
      for (final ground in await grounds(light: true, vivid: true)) {
        final c = contrast(onCover.textSecondary, ground);
        if (c < worst) worst = c;
      }
      expect(worst, greaterThanOrEqualTo(4.5));
    });
  });

  for (final light in [true, false]) {
    final name = light ? 'light' : 'dark';
    final onCover = (light ? Palette.light : Palette.dark).onCover;

    testWidgets('on the colours of a cover, words keep 4.5:1 ($name)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        var worst = double.infinity;
        for (final ground in await grounds(light: light)) {
          final c = contrast(onCover.textSecondary, ground);
          if (c < worst) worst = c;
        }
        expect(worst, greaterThanOrEqualTo(4.5));
      });
    });

    testWidgets(
      'on the colours of a cover, a name that is a link keeps 4.5:1 ($name)',
      (tester) async {
        await tester.runAsync(() async {
          final base = light ? Palette.light : Palette.dark;
          var worst = double.infinity;
          for (final ground in await grounds(light: light)) {
            final c = contrast(base.link, ground);
            if (c < worst) worst = c;
          }
          expect(worst, greaterThanOrEqualTo(4.5));
        });
      },
    );

    testWidgets('on the colours of a cover, icons keep 3:1 ($name)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        var worst = double.infinity;
        for (final ground in await grounds(light: light)) {
          final c = contrast(onCover.textTertiary, ground);
          if (c < worst) worst = c;
        }
        expect(worst, greaterThanOrEqualTo(3));
      });
    });
  }

  test('only the quiet colours change on a cover', () {
    final p = Palette.light;
    expect(p.onCover.text, p.text);
    expect(p.onCover.primary, p.primary);
    expect(p.onCover.base, p.base);
    expect(p.onCover.textSecondary, isNot(p.textSecondary));
  });
}
