import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../format.dart';
import '../strings.dart';

/// One comment of a YouTube video, or one reply to one. Every text is as YouTube wrote it, in the language it was asked
/// for: "4 years ago", "9.8K".
@immutable
class YoutubeComment {
  const YoutubeComment({
    required this.id,
    required this.author,
    required this.text,
    this.avatar,
    this.time = '',
    this.likes,
    this.replies,
    this.repliesToken,
    this.creator = false,
    this.verified = false,
    this.pinned = false,
  });

  final String id;
  final String author;
  final String text;
  final String? avatar;
  final String time;

  /// What YouTube shows beside the thumb ("9.8K"); null for none.
  final String? likes;

  /// How many replies there are ("548"); null for none.
  final String? replies;

  /// What the replies are asked for with.
  final String? repliesToken;

  /// The channel of the video wrote it, or is the artist of the song.
  final bool creator;
  final bool verified;
  final bool pinned;
}

/// A page of comments: the first has the total and what to ask for to sort another way.
@immutable
class CommentsPage {
  const CommentsPage({
    this.total,
    this.comments = const [],
    this.next,
    this.sorts = const [],
  });

  /// How many comments the video has ("1,259,584"), said in the language of the app; null when not said.
  final String? total;
  final List<YoutubeComment> comments;

  /// What the page after this one is asked for with; null on the last.
  final String? next;

  /// What each way to sort is asked for with, in the order of YouTube's menu: top, then newest.
  final List<String> sorts;
}

/// What the first ask for a video gives: the way into its comments, or that it has none to read.
String? commentsToken(String body) {
  final json = jsonDecode(body);
  String? found;
  void walk(Object? node) {
    if (found != null) return;
    if (node is Map) {
      if (node['sectionIdentifier'] == 'comment-item-section') {
        found = _tokenIn(node['contents']);
        if (found != null) return;
      }
      for (final value in node.values) {
        walk(value);
      }
    } else if (node is List) {
      for (final value in node) {
        walk(value);
      }
    }
  }

  walk(json);
  return found;
}

/// The token of the first `continuationCommand` inside [node]: where a "more" or "replies" button leads.
String? _tokenIn(Object? node) {
  if (node is Map) {
    final command = node['continuationCommand'];
    if (command is Map && command['token'] is String) return command['token'] as String;
    for (final value in node.values) {
      final token = _tokenIn(value);
      if (token != null) return token;
    }
  } else if (node is List) {
    for (final value in node) {
      final token = _tokenIn(value);
      if (token != null) return token;
    }
  }
  return null;
}

/// Reads an answer of YouTube's `next` that holds comments: the first page (with its header), a later page, or the
/// replies of a comment. The words of a comment sit in `frameworkUpdates`, apart from the list that gives their order,
/// so the two are put together by the comment's id.
CommentsPage parseCommentsPage(String body) {
  final json = jsonDecode(body);
  if (json is! Map) return const CommentsPage();
  final entities = <String, Map<dynamic, dynamic>>{};
  final mutations = _list(_at(json, ['frameworkUpdates', 'entityBatchUpdate', 'mutations']));
  for (final mutation in mutations) {
    final payload = _at(mutation, ['payload', 'commentEntityPayload']);
    final id = _at(payload, ['properties', 'commentId']);
    if (payload is Map && id is String) entities[id] = payload;
  }

  String? total;
  String? next;
  var sorts = <String>[];
  final comments = <YoutubeComment>[];
  for (final endpoint in _list(json['onResponseReceivedEndpoints'])) {
    if (endpoint is! Map) continue;
    final command = endpoint['reloadContinuationItemsCommand'] ?? endpoint['appendContinuationItemsAction'];
    for (final item in _list(_at(command, ['continuationItems']))) {
      if (item is! Map) continue;
      if (item['commentsHeaderRenderer'] case final Map header) {
        total = _total(_at(header, ['countText', 'runs']));
        final menu = _list(_at(header, ['sortMenu', 'sortFilterSubMenuRenderer', 'subMenuItems']));
        sorts = [for (final entry in menu) ?_tokenIn(entry)];
      } else if (item['commentThreadRenderer'] case final Map thread) {
        final view = _at(thread, ['commentViewModel', 'commentViewModel']);
        final id = _at(view, ['commentId']);
        final entity = id is String ? entities[id] : null;
        if (entity == null) continue;
        comments.add(
          _comment(
            entity,
            pinned: _at(view, ['pinnedText']) is String,
            repliesToken: _tokenIn(_at(thread, ['replies', 'commentRepliesRenderer', 'contents'])),
          ),
        );
      } else if (item['commentViewModel'] case final Map view) {
        final id = view['commentId'];
        final entity = id is String ? entities[id] : null;
        if (entity != null) comments.add(_comment(entity));
      } else if (item['continuationItemRenderer'] != null) {
        next = _tokenIn(item['continuationItemRenderer']);
      }
    }
  }
  return CommentsPage(total: total, comments: comments, next: next, sorts: sorts);
}

YoutubeComment _comment(Map<dynamic, dynamic> entity, {bool pinned = false, String? repliesToken}) {
  String? text(Object? value) {
    final s = value is String ? value.trim() : '';
    return s.isEmpty ? null : s;
  }

  final properties = entity['properties'];
  final toolbar = entity['toolbar'];
  final author = entity['author'];
  return YoutubeComment(
    id: _at(properties, ['commentId']) as String,
    author: text(_at(author, ['displayName'])) ?? '',
    text: (_at(properties, ['content', 'content']) as String?) ?? '',
    avatar: text(_at(author, ['avatarThumbnailUrl'])),
    time: text(_at(properties, ['publishedTime'])) ?? '',
    // A comment nobody liked has a blank count, not a 0
    likes: text(_at(toolbar, ['likeCountNotliked'])),
    replies: repliesToken == null ? null : text(_at(toolbar, ['replyCount'])),
    repliesToken: repliesToken,
    creator: _at(author, ['isCreator']) == true || _at(author, ['isArtist']) == true,
    verified: _at(author, ['isVerified']) == true,
    pinned: pinned,
  );
}

/// "1,259,584 Comments" as the runs of it come: the number is a run of its own. Said short ("1.3M") in the language
/// of the app; a number that cannot be read is given as YouTube wrote it.
String? _total(Object? runs) {
  final first = _list(runs).firstOrNull;
  final text = first is Map && first['text'] is String ? (first['text'] as String).trim() : '';
  if (text.isEmpty) return null;
  final digits = text.replaceAll(RegExp(r'[,.\s]'), '');
  final count = RegExp(r'^\d+$').hasMatch(digits) ? int.tryParse(digits) : null;
  return count == null ? text : formatCount(count);
}

Object? _at(Object? node, List<String> path) {
  var at = node;
  for (final key in path) {
    if (at is! Map) return null;
    at = at[key];
  }
  return at;
}

List<dynamic> _list(Object? node) => node is List ? node : const [];

/// Sends the body of a request to YouTube's `next` and gives back the answer text.
typedef CommentsTransport = Future<String> Function(String body);

/// The comments of YouTube as the website asks for them, for a person who is not signed in (so they can be read, not
/// written). It is not a documented API and can change: a page that cannot be read is an error, which the player shows
/// as one and never lets reach the music.
///
/// Two asks open a video's comments (its page, which has the way in, then the way in), and one more per page after that.
/// The answers are 100 to 500 KB of JSON before they are packed, so they are read off the main thread where there is
/// one to read them on.
class CommentsClient {
  CommentsClient(this._transport, {String Function()? region, bool offload = true})
    : _region = region ?? (() => 'US'),
      _offload = offload && !kIsWeb;

  final CommentsTransport _transport;
  final String Function() _region;
  final bool _offload;

  static const clientName = 'WEB';
  static const clientVersion = '2.20251110.01.00';

  /// The comments of a song or video, from the top; null when it has none to read (they are turned off).
  Future<CommentsPage?> open(String videoId) async {
    final token = await _read(commentsToken, await _ask({'videoId': videoId}));
    return token == null ? null : page(token);
  }

  /// A page of comments, replies or other way of sorting, by what the page before it said.
  Future<CommentsPage> page(String token) async => _read(parseCommentsPage, await _ask({'continuation': token}));

  Future<R> _read<R>(R Function(String body) parse, String body) =>
      _offload ? compute(parse, body) : Future.value(parse(body));

  Future<String> _ask(Map<String, Object?> fields) {
    final region = _region();
    return _transport(
      jsonEncode({
        'context': {
          'client': {
            'clientName': clientName,
            'clientVersion': clientVersion,
            // The words of the comments ("4 years ago") are of the language of the app
            'hl': S.current,
            'gl': region.isEmpty ? 'US' : region,
          },
        },
        ...fields,
      }),
    );
  }
}

/// The replies of a comment, as far as they were asked for.
class Replies {
  List<YoutubeComment> items = [];
  String? next;
  bool loading = false;
  bool failed = false;
}

/// The comments of one song, as far as the person has read them. It asks when the panel is opened and not before, a page
/// more when they near the end, and the replies of a comment when they open them.
class CommentsFeed extends ChangeNotifier {
  CommentsFeed(this._client, this.videoId);

  final CommentsClient _client;
  final String videoId;

  var _comments = <YoutubeComment>[];
  String? _total;
  String? _next;
  var _sorts = <String>[];
  var _sort = 0;
  var _started = false;
  var _loading = false;
  var _loadingMore = false;
  var _failed = false;
  var _off = false;
  var _disposed = false;

  /// Said once a page of this feed was asked for with the other way of sorting; answers of the way left are let go.
  var _round = 0;

  final replies = <String, Replies>{};

  List<YoutubeComment> get comments => _comments;
  String? get total => _total;
  int get sort => _sort;

  /// Whether there is a second way to sort, which only the first page says.
  bool get canSort => _sorts.length > 1;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get failed => _failed;

  /// The video has no comments to read (turned off).
  bool get off => _off;
  bool get hasMore => _next != null;

  /// Asks for the first page, once; a ask that failed is made again by asking again.
  Future<void> start() async {
    if (_started && !_failed) return;
    _started = true;
    _failed = false;
    _loading = true;
    _notify();
    final round = ++_round;
    try {
      final page = await _client.open(videoId);
      if (round != _round) return;
      if (page == null) {
        _off = true;
      } else {
        _take(page);
      }
    } on Object {
      if (round != _round) return;
      _failed = true;
    }
    _loading = false;
    _notify();
  }

  void _take(CommentsPage page) {
    _comments = page.comments;
    _total = page.total ?? _total;
    _next = page.next;
    if (page.sorts.isNotEmpty) _sorts = page.sorts;
  }

  /// Sorts the comments the other way, and asks for them from the top.
  Future<void> setSort(int index) async {
    if (index == _sort || index >= _sorts.length || _loading) return;
    _sort = index;
    _loading = true;
    _failed = false;
    _comments = [];
    _next = null;
    replies.clear();
    _notify();
    final round = ++_round;
    try {
      final page = await _client.page(_sorts[index]);
      if (round != _round) return;
      _take(page);
    } on Object {
      if (round != _round) return;
      _failed = true;
      // Asking again starts from the top the way it was
      _sort = 0;
      _started = false;
    }
    _loading = false;
    _notify();
  }

  /// The page after the last, when the person nears the end of the list.
  Future<void> more() async {
    final token = _next;
    if (token == null || _loadingMore || _loading) return;
    _loadingMore = true;
    _notify();
    final round = _round;
    try {
      final page = await _client.page(token);
      if (round != _round) return;
      final known = {for (final c in _comments) c.id};
      _comments = [..._comments, for (final c in page.comments) if (!known.contains(c.id)) c];
      _next = page.next;
    } on Object {
      // The list stays as it is; the next touch of the end asks again
    }
    _loadingMore = false;
    _notify();
  }

  /// Opens or shuts the replies of [comment]; the first time asks for them.
  Future<void> toggleReplies(YoutubeComment comment) async {
    final token = comment.repliesToken;
    if (token == null) return;
    final open = replies[comment.id];
    if (open != null && !open.failed) {
      // A touch again shuts them; they are kept, so that opening them again asks for nothing
      replies.remove(comment.id);
      _notify();
      return;
    }
    await _loadReplies(comment.id, token, open ?? Replies());
  }

  /// More replies of an opened comment.
  Future<void> moreReplies(YoutubeComment comment) async {
    final open = replies[comment.id];
    final token = open?.next;
    if (open == null || token == null || open.loading) return;
    await _loadReplies(comment.id, token, open);
  }

  Future<void> _loadReplies(String id, String token, Replies state) async {
    replies[id] = state
      ..loading = true
      ..failed = false;
    _notify();
    final round = _round;
    try {
      final page = await _client.page(token);
      if (round != _round) return;
      state
        ..items = [...state.items, ...page.comments]
        ..next = page.next;
    } on Object {
      state.failed = true;
    }
    state.loading = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The feeds of the songs seen lately, so that going back to one does not ask again.
class CommentsController {
  CommentsController(this._client);

  final CommentsClient _client;

  static const _keep = 5;
  final _feeds = <String, CommentsFeed>{};

  CommentsFeed feed(String videoId) {
    final kept = _feeds.remove(videoId);
    final feed = kept ?? CommentsFeed(_client, videoId);
    _feeds[videoId] = feed;
    // A feed that is let go is not disposed: a panel may still be showing it as the song changes under it
    while (_feeds.length > _keep) {
      _feeds.remove(_feeds.keys.first);
    }
    return feed;
  }
}
