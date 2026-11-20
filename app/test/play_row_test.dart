import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/widgets/play_row.dart';

Widget _row(double width, {bool inline = false}) => MaterialApp(
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
          download: const IconButton(onPressed: null, icon: Icon(Icons.download)),
          more: const IconButton(onPressed: null, icon: Icon(Icons.more_horiz)),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('Play is a pill with its word where there is room for it', (tester) async {
    await tester.pumpWidget(_row(420));
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
}
