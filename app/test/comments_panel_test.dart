import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/comments.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/strings.dart';
import 'package:sapoche/ui/now_playing_page.dart';
import 'package:sapoche/ui/player/comments_view.dart';

import 'comments_test.dart' show FakeYoutube, fixture;
import 'fake_backend.dart';
import 'pump_app.dart';

/// The comments of YouTube in the full player: the panel that takes the cover's place, as the lyrics and the queue do.
void main() {
  late FakeYoutube youtube;

  setUp(() {
    youtube = FakeYoutube();
    final top = parseCommentsPage(fixture('page_top.json'));
    youtube.answers[commentsToken(fixture('watch_next.json'))!] = fixture('page_top.json');
    youtube.answers[top.next!] = fixture('page_more.json');
    youtube.answers[top.comments.first.repliesToken!] = fixture('replies.json');
    youtube.answers[top.sorts[1]] = fixture('page_more.json');
  });

  Future<FakeBackend> openPlayer(WidgetTester tester, {String stats = '4.2M views · 6.4M likes'}) async {
    final (backend, _) = await pumpApp(tester, commentsTransport: youtube.call);
    backend.radioResult = SongRadio(
      tracks: [MusicTrack(videoId: 'video0', title: 'Song 0', artist: 'Artist 0', durMs: 200000, stats: stats)],
    );
    backend.emit(StateEvent(sampleRoom()));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await goHome(tester);
    await tapMiniPlayer(tester);
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);
    return backend;
  }

  Future<void> openComments(WidgetTester tester) async {
    await tester.tap(find.byTooltip(S.youtubeComments));
    await tester.pumpAndSettle();
  }

  testWidgets('asks for nothing until the panel is opened, then shows the total, the likes and the comments', (
    tester,
  ) async {
    await openPlayer(tester);
    expect(youtube.bodies, isEmpty);
    expect(find.byType(CommentsView), findsNothing);

    await openComments(tester);
    expect(find.byType(CommentsView), findsOneWidget);
    expect(find.text('${S.comments} · 1.3M'), findsOneWidget);
    expect(find.text('6.4M'), findsOneWidget, reason: 'the likes of the video');
    expect(find.text('@viewer0'), findsNothing, reason: 'the name is in a line with the time');
    expect(find.textContaining('@viewer0'), findsOneWidget);
    expect(find.text(S.commentsPinned), findsOneWidget);
    expect(find.text('Câu thử bằng tiếng Việt, có emoji 🌻 và dấu.'), findsOneWidget);
    expect(find.text(S.commentReplies('548')), findsOneWidget);
    expect(find.text(S.commentsTop), findsOneWidget);
    expect(find.text(S.commentsNewest), findsOneWidget);
    expect(youtube.bodies, hasLength(2));
  });

  testWidgets('a comment that is long is cut and opens by a touch', (tester) async {
    await openPlayer(tester);
    await openComments(tester);
    expect(find.text(S.commentsReadMore), findsOneWidget);
    await tester.tap(find.text(S.commentsReadMore));
    await tester.pumpAndSettle();
    expect(find.text(S.commentsReadLess), findsOneWidget);
    expect(find.text(S.commentsReadMore), findsNothing);
  });

  testWidgets('the replies open under the comment, and shut', (tester) async {
    await openPlayer(tester);
    await openComments(tester);
    await tester.tap(find.text(S.commentReplies('548')));
    await tester.pumpAndSettle();
    expect(find.textContaining('@viewer7'), findsOneWidget);
    expect(find.text(S.commentsHideReplies), findsOneWidget);
    await tester.tap(find.text(S.commentsHideReplies));
    await tester.pumpAndSettle();
    expect(find.textContaining('@viewer7'), findsNothing);
    expect(find.text(S.commentReplies('548')), findsOneWidget);
  });

  testWidgets('the newest comments are asked for from the top', (tester) async {
    await openPlayer(tester);
    await openComments(tester);
    await tester.tap(find.text(S.commentsNewest));
    await tester.pumpAndSettle();
    expect(find.text('Câu thử bằng tiếng Việt, có emoji 🌻 và dấu.'), findsNothing);
    expect(find.textContaining('@viewer4'), findsOneWidget);
  });

  testWidgets('Back goes to the cover first, and the button goes back as well', (tester) async {
    await openPlayer(tester);
    await openComments(tester);
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(CommentsView), findsNothing);
    expect(find.byType(NowPlayingPage), findsOneWidget);

    await openComments(tester);
    await tester.tap(find.byTooltip(S.youtubeComments));
    await tester.pumpAndSettle();
    expect(find.byType(CommentsView), findsNothing);
  });

  testWidgets('comments that are turned off say so', (tester) async {
    youtube = FakeYoutube(video: 'watch_next_off.json');
    await openPlayer(tester);
    await openComments(tester);
    expect(find.text(S.commentsOff), findsOneWidget);
  });

  testWidgets('a failure offers to try again', (tester) async {
    youtube.failWith = const SocketException('no network');
    await openPlayer(tester);
    await openComments(tester);
    expect(find.text(S.commentsFailed), findsOneWidget);
    youtube.failWith = null;
    await tester.tap(find.text(S.tryAgain));
    await tester.pumpAndSettle();
    expect(find.text(S.commentsFailed), findsNothing);
    expect(find.text('${S.comments} · 1.3M'), findsOneWidget);
  });

  testWidgets('a song that YouTube Music gives no likes for has none in the header', (tester) async {
    await openPlayer(tester, stats: '9M plays');
    await openComments(tester);
    expect(find.text('${S.comments} · 1.3M'), findsOneWidget);
    expect(find.text('6.4M'), findsNothing);
    expect(find.bySemanticsLabel(S.likeCount('6.4M')), findsNothing);
  });
}
