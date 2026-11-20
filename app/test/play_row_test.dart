import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/widgets/play_row.dart';

Widget _row(double width, {bool inline = false, bool withDownload = true}) => MaterialApp(
  theme: buildTheme(Palette.dark),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: PlayRow(
          inline: inline,
          onPlay: () {},
          onShuffle: () {},
          download: withDownload ? const IconButton(onPressed: null, icon: Icon(Icons.download)) : null,
          more: const IconButton(onPressed: null, icon: Icon(Icons.more_horiz)),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('Play is a pill with its word where there is room for it', (tester) async {
    await tester.pumpWidget(_row(520));
    expect(find.text(S.play), findsOneWidget);
  });

  testWidgets('Play is a round button, with no word, where the round buttons leave it too little', (tester) async {
    // Inline, a column that narrow puts the round buttons under Play, unless the phone is on its side
    tester.view.physicalSize = const Size(900, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final inline in [false, true]) {
      await tester.pumpWidget(_row(300, inline: inline));
      expect(find.text(S.play), findsNothing, reason: 'inline: $inline');
      final play = find.byTooltip(S.play);
      expect(play, findsOneWidget);
      expect(tester.getSize(play).width, tester.getSize(play).height);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('on a screen on its side a page with only Shuffle and More still has a round Play when it is narrow', (
    tester,
  ) async {
    // A playlist from YouTube has no Download: Play has 172 of the 300, which is room enough on a phone held upright...
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_row(300, withDownload: false));
    expect(find.text(S.play), findsOneWidget);
    // ...and not on its side, beside the player
    tester.view.physicalSize = const Size(1200, 700);
    await tester.pumpWidget(_row(300, withDownload: false));
    expect(find.text(S.play), findsNothing);
    expect(find.byTooltip(S.play), findsOneWidget);
  });
}
