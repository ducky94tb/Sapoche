import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/comments.dart';
import 'package:sapoche/format.dart';
import 'package:sapoche/strings.dart';

String fixture(String name) => File('test/fixtures/comments/$name').readAsStringSync();

/// The answers of YouTube, by what is asked: the page of a video, then a page, replies or another sorting by token.
class FakeYoutube {
  FakeYoutube({this.video = 'watch_next.json'});

  final String video;
  final bodies = <Map<String, Object?>>[];
  final answers = <String, String>{};
  Object? failWith;

  Future<String> call(String body) async {
    final json = jsonDecode(body) as Map<String, Object?>;
    bodies.add(json);
    if (failWith != null) throw failWith!;
    if (json['videoId'] != null) return fixture(video);
    final token = json['continuation'] as String;
    return answers[token] ?? (throw StateError('no answer for $token'));
  }
}

String tokenOf(String page, List<String> path) {
  Object? at = jsonDecode(page);
  for (final key in path) {
    at = at is List ? at[int.parse(key)] : (at as Map)[key];
  }
  return at as String;
}

void main() {
  tearDown(() => S.current = 'en');

  group('parser', () {
    test('finds the way into the comments on the page of a video', () {
      expect(commentsToken(fixture('watch_next.json')), startsWith('Eg0SC2tuVzcteDdZN1JFGAYy'));
    });

    test('says there is none when the comments are turned off', () {
      expect(commentsToken(fixture('watch_next_off.json')), isNull);
      expect(commentsToken('{}'), isNull);
    });

    test('puts together the list and the words of the first page', () {
      final page = parseCommentsPage(fixture('page_top.json'));
      expect(page.total, '1.3M');
      expect(page.comments, hasLength(4));
      expect(page.sorts, hasLength(2));
      expect(page.next, isNotNull);
      final first = page.comments.first;
      expect(first.pinned, isTrue);
      expect(first.author, '@viewer0');
      expect(first.likes, '9.8K');
      expect(first.replies, '548');
      expect(first.repliesToken, isNotNull);
      expect(first.text, startsWith('Pinned test comment'));
      expect(page.comments[1].pinned, isFalse);
      expect(page.comments[1].time, isNotEmpty);
      expect(page.comments[1].text, 'Câu thử bằng tiếng Việt, có emoji 🌻 và dấu.');
    });

    test('says the total in the language of the app', () {
      S.current = 'vi';
      expect(parseCommentsPage(fixture('page_top.json')).total, '1,3 Tr');
    });

    test('reads a later page: no header, comments, the page after it', () {
      final page = parseCommentsPage(fixture('page_more.json'));
      expect(page.total, isNull);
      expect(page.sorts, isEmpty);
      expect(page.comments, hasLength(3));
      expect(page.next, isNotNull);
    });

    test('reads the replies of a comment and where more of them are', () {
      final page = parseCommentsPage(fixture('replies.json'));
      expect(page.comments, hasLength(3));
      expect(page.comments.every((c) => c.repliesToken == null && c.replies == null), isTrue);
      expect(page.next, isNotNull);
    });

    test('a page that cannot be read gives nothing, a text that is not JSON throws', () {
      expect(parseCommentsPage('[]').comments, isEmpty);
      expect(parseCommentsPage('{"onResponseReceivedEndpoints": 3}').comments, isEmpty);
      expect(() => parseCommentsPage('<html>'), throwsFormatException);
    });
  });

  group('client', () {
    test('asks for the video, then for the way in, as a browser that is not signed in', () async {
      final youtube = FakeYoutube();
      final token = commentsToken(fixture('watch_next.json'))!;
      youtube.answers[token] = fixture('page_top.json');
      final page = await CommentsClient(youtube.call, region: () => 'VN', offload: false).open('knW7-x7Y7RE');
      expect(page!.comments, hasLength(4));
      expect(youtube.bodies, hasLength(2));
      expect(youtube.bodies[0]['videoId'], 'knW7-x7Y7RE');
      expect(youtube.bodies[1]['continuation'], token);
      final client = (youtube.bodies[0]['context'] as Map)['client'] as Map;
      expect(client, {'clientName': 'WEB', 'clientVersion': CommentsClient.clientVersion, 'hl': 'en', 'gl': 'VN'});
    });

    test('asks in the language of the app', () async {
      S.current = 'vi';
      final youtube = FakeYoutube(video: 'watch_next_off.json');
      await CommentsClient(youtube.call, offload: false).open('abc');
      expect(((youtube.bodies[0]['context'] as Map)['client'] as Map)['hl'], 'vi');
    });

    test('reads the answers in another isolate unless told not to', () async {
      final youtube = FakeYoutube();
      youtube.answers[commentsToken(fixture('watch_next.json'))!] = fixture('page_top.json');
      final page = await CommentsClient(youtube.call).open('knW7-x7Y7RE');
      expect(page!.comments, hasLength(4));
    });

    test('stops after one ask when the comments are off', () async {
      final youtube = FakeYoutube(video: 'watch_next_off.json');
      expect(await CommentsClient(youtube.call, offload: false).open('abc'), isNull);
      expect(youtube.bodies, hasLength(1));
    });
  });

  group('feed', () {
    late FakeYoutube youtube;
    late CommentsFeed feed;
    late String sortToken;
    late String moreToken;
    late String repliesToken;

    setUp(() {
      youtube = FakeYoutube();
      final top = parseCommentsPage(fixture('page_top.json'));
      youtube.answers[commentsToken(fixture('watch_next.json'))!] = fixture('page_top.json');
      moreToken = top.next!;
      sortToken = top.sorts[1];
      repliesToken = top.comments.first.repliesToken!;
      youtube.answers[moreToken] = fixture('page_more.json');
      youtube.answers[repliesToken] = fixture('replies.json');
      // The other sorting gives a page of its own; the second page of the first has the same comments as the first
      youtube.answers[sortToken] = fixture('page_more.json');
      feed = CommentsFeed(CommentsClient(youtube.call, offload: false), 'knW7-x7Y7RE');
    });

    test('asks once, when started', () async {
      await Future.wait([feed.start(), feed.start()]);
      await feed.start();
      expect(feed.comments, hasLength(4));
      expect(feed.total, '1.3M');
      expect(feed.canSort, isTrue);
      expect(feed.loading, isFalse);
      expect(youtube.bodies, hasLength(2));
    });

    test('a page more is put after the comments, and one that was there is not put twice', () async {
      await feed.start();
      await Future.wait([feed.more(), feed.more()]);
      expect(feed.comments, hasLength(7));
      expect(feed.comments.map((c) => c.id).toSet(), hasLength(7));
      expect(youtube.bodies.where((b) => b['continuation'] == moreToken), hasLength(1));
    });

    test('sorting the other way asks from the top and keeps the total', () async {
      await feed.start();
      await feed.setSort(1);
      expect(feed.sort, 1);
      expect(feed.comments, hasLength(3));
      expect(feed.total, '1.3M');
      expect(youtube.bodies.last['continuation'], sortToken);
    });

    test('replies open, are kept as they are shut, and more of them can be had', () async {
      await feed.start();
      final comment = feed.comments.first;
      await feed.toggleReplies(comment);
      expect(feed.replies[comment.id]!.items, hasLength(3));
      expect(feed.replies[comment.id]!.next, isNotNull);
      await feed.toggleReplies(comment);
      expect(feed.replies, isEmpty);
    });

    test('a feed that failed asks again when asked again, and says so meanwhile', () async {
      youtube.failWith = const SocketException('no network');
      await feed.start();
      expect(feed.failed, isTrue);
      expect(feed.comments, isEmpty);
      youtube.failWith = null;
      await feed.start();
      expect(feed.failed, isFalse);
      expect(feed.comments, hasLength(4));
    });

    test('a page that fails leaves the list as it is', () async {
      await feed.start();
      youtube.failWith = const SocketException('no network');
      await feed.more();
      expect(feed.comments, hasLength(4));
      expect(feed.failed, isFalse);
      expect(feed.loadingMore, isFalse);
    });

    test('comments that are off are known as off', () async {
      final off = CommentsFeed(CommentsClient(FakeYoutube(video: 'watch_next_off.json').call, offload: false), 'x');
      await off.start();
      expect(off.off, isTrue);
      expect(off.failed, isFalse);
    });
  });

  test('the controller keeps the feeds of the last five songs', () {
    final controller = CommentsController(CommentsClient((_) async => '{}', offload: false));
    final first = controller.feed('a');
    for (final id in ['b', 'c', 'd', 'e']) {
      controller.feed(id);
    }
    expect(controller.feed('a'), same(first));
    for (final id in ['f', 'g', 'h', 'i', 'j']) {
      controller.feed(id);
    }
    expect(controller.feed('a'), isNot(same(first)));
  });

  group('likes of a video', () {
    test('are taken from the line YouTube Music gives, in the language of the app', () {
      expect(splitViews('1.8B views · 19M likes').likes, '19M');
      expect(splitViews('1.8B views • 4,201,234 likes').likes, '4.2M');
      expect(splitViews('155M plays').likes, isNull);
      S.current = 'vi';
      expect(splitViews('1.8B views · 19M likes').likes, '19 Tr');
    });
  });
}
