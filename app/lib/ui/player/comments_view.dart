import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/comments.dart';
import '../../data/models.dart';
import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import '../widgets/avatars.dart';
import '../widgets/cached_cover.dart';
import 'player_message.dart';

/// What people wrote under the song on YouTube, to read: the comments from the top or the newest, the replies of one,
/// and how many liked the song when YouTube says. Writing and liking need a YouTube account, which the app does not
/// have, so the last line sends whoever wants to comment to YouTube.
class CommentsView extends StatefulWidget {
  const CommentsView({super.key, required this.controller, required this.track});

  final RoomController controller;
  final Track track;

  @override
  State<CommentsView> createState() => _CommentsViewState();
}

class _CommentsViewState extends State<CommentsView> {
  CommentsFeed? _feed;
  Future<String?>? _likes;
  String? _for;

  /// Whether it is waiting for the song to have sound (it listens to the controller until it does).
  bool _waiting = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_for == null) _use();
  }

  @override
  void didUpdateWidget(CommentsView old) {
    super.didUpdateWidget(old);
    if (widget.track.videoId != _for) _use();
  }

  @override
  void dispose() {
    if (_waiting) widget.controller.removeListener(_ask);
    super.dispose();
  }

  void _use() {
    final app = AppScope.of(context);
    _for = widget.track.videoId;
    _feed = app.comments.feed(_for!);
    _likes = app.music.likesOf(widget.track);
    _ask();
  }

  /// The start of a song has the network to itself: the comments are asked for once it has sound.
  void _ask() {
    final starting = widget.controller.isStarting;
    if (starting != _waiting) {
      _waiting = starting;
      if (starting) {
        widget.controller.addListener(_ask);
      } else {
        widget.controller.removeListener(_ask);
      }
    }
    if (!starting) _feed?.start();
  }

  @override
  Widget build(BuildContext context) {
    final feed = _feed!;
    return ListenableBuilder(
      key: ValueKey(_for),
      listenable: feed,
      builder: (context, _) {
        if (feed.off) {
          return PlayerMessage(icon: Icons.comments_disabled_outlined, text: S.commentsOff);
        }
        if (feed.failed && feed.comments.isEmpty) {
          return PlayerMessage(
            icon: Icons.cloud_off_rounded,
            text: S.commentsFailed,
            action: S.tryAgain,
            onAction: feed.start,
          );
        }
        if (feed.loading && feed.comments.isEmpty) return const _Skeleton();
        if (feed.comments.isEmpty) {
          return PlayerMessage(icon: Icons.chat_bubble_outline_rounded, text: S.commentsNone);
        }
        return _CommentList(feed: feed, likes: _likes!, videoId: _for!);
      },
    );
  }
}

/// One row of the list: the header, a comment or a reply, the button of the replies, or the foot.
sealed class _Row {}

class _Header extends _Row {}

class _Foot extends _Row {}

class _Item extends _Row {
  _Item(this.comment, {this.reply = false});
  final YoutubeComment comment;
  final bool reply;
}

class _RepliesButton extends _Row {
  _RepliesButton(this.comment, {required this.open, required this.loading, required this.failed});
  final YoutubeComment comment;
  final bool open;
  final bool loading;
  final bool failed;
}

class _MoreReplies extends _Row {
  _MoreReplies(this.comment, {required this.loading});
  final YoutubeComment comment;
  final bool loading;
}

class _CommentList extends StatelessWidget {
  const _CommentList({required this.feed, required this.likes, required this.videoId});

  final CommentsFeed feed;
  final Future<String?> likes;
  final String videoId;

  /// How far from the end the next page is asked for: about three screens of comments before they run out.
  static const _ahead = 900.0;

  List<_Row> _rows() {
    final rows = <_Row>[_Header()];
    for (final comment in feed.comments) {
      rows.add(_Item(comment));
      final replies = feed.replies[comment.id];
      if (comment.repliesToken == null) continue;
      rows.add(
        _RepliesButton(
          comment,
          open: replies != null && !replies.failed,
          loading: replies?.loading ?? false,
          failed: replies?.failed ?? false,
        ),
      );
      if (replies != null) {
        for (final reply in replies.items) {
          rows.add(_Item(reply, reply: true));
        }
        if (replies.next != null) rows.add(_MoreReplies(comment, loading: replies.loading));
      }
    }
    rows.add(_Foot());
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical && n.metrics.extentAfter < _ahead) feed.more();
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: rows.length,
        itemBuilder: (context, i) => switch (rows[i]) {
          _Header() => _HeaderRow(feed: feed, likes: likes),
          _Item(:final comment, :final reply) => _CommentRow(key: ValueKey(comment.id), comment: comment, reply: reply),
          _RepliesButton row => _RepliesRow(feed: feed, row: row),
          _MoreReplies(:final comment, :final loading) => _TextAction(
            indent: 44,
            label: S.commentsMoreReplies,
            loading: loading,
            onTap: () => feed.moreReplies(comment),
          ),
          _Foot() => _FootRow(feed: feed, videoId: videoId),
        },
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.feed, required this.likes});

  final CommentsFeed feed;
  final Future<String?> likes;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final total = feed.total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  total == null ? S.comments : '${S.comments} · $total',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              // How many liked the song, where YouTube says (a song's own page does not, a video's does)
              FutureBuilder<String?>(
                future: likes,
                builder: (context, snapshot) {
                  final text = snapshot.data;
                  if (text == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Semantics(
                      label: S.likeCount(text),
                      excludeSemantics: true,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.thumb_up_outlined, size: 16, color: p.textSecondary),
                          const SizedBox(width: 6),
                          Text(text, style: theme.bodyMedium?.copyWith(color: p.textSecondary)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          if (feed.canSort)
            Row(
              children: [
                _SortPill(label: S.commentsTop, selected: feed.sort == 0, onTap: () => feed.setSort(0)),
                _SortPill(label: S.commentsNewest, selected: feed.sort == 1, onTap: () => feed.setSort(1)),
              ],
            ),
        ],
      ),
    );
  }
}

class _SortPill extends StatelessWidget {
  const _SortPill({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // The pill is 32 high; the place that answers a touch is 48
        child: SizedBox(
          height: 48,
          child: Center(
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? p.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                border: selected ? null : Border.all(color: p.outline),
              ),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: selected ? p.onPrimary : p.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CommentRow extends StatefulWidget {
  const _CommentRow({super.key, required this.comment, required this.reply});

  final YoutubeComment comment;
  final bool reply;

  @override
  State<_CommentRow> createState() => _CommentRowState();
}

class _CommentRowState extends State<_CommentRow> {
  static const _lines = 4;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final c = widget.comment;
    final size = widget.reply ? 24.0 : 32.0;
    final secondary = theme.bodySmall?.copyWith(color: p.textSecondary);
    final body = theme.bodyMedium?.copyWith(height: 1.35);
    return Padding(
      padding: EdgeInsets.fromLTRB(widget.reply ? 44 : 4, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Photo(url: c.avatar, name: c.author, size: size),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.pinned)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Row(
                      children: [
                        Icon(Icons.push_pin_outlined, size: 13, color: p.textSecondary),
                        const SizedBox(width: 4),
                        Text(S.commentsPinned, style: secondary),
                      ],
                    ),
                  ),
                Text.rich(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  TextSpan(
                    children: [
                      TextSpan(
                        text: c.author,
                        style: secondary?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: c.creator ? p.link : p.textSecondary,
                        ),
                      ),
                      if (c.creator)
                        TextSpan(text: ' · ${S.commentsCreator}', style: secondary?.copyWith(color: p.link)),
                      if (c.time.isNotEmpty) TextSpan(text: ' · ${c.time}', style: secondary),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                LayoutBuilder(
                  builder: (context, box) {
                    final painter = TextPainter(
                      text: TextSpan(text: c.text, style: body),
                      textDirection: Directionality.of(context),
                      textScaler: MediaQuery.textScalerOf(context),
                      maxLines: _lines,
                    )..layout(maxWidth: box.maxWidth);
                    final longer = painter.didExceedMaxLines;
                    final text = Text(
                      c.text,
                      style: body,
                      maxLines: _expanded ? null : _lines,
                      overflow: _expanded ? TextOverflow.clip : TextOverflow.ellipsis,
                    );
                    if (!longer) return text;
                    // The whole text answers a touch: it is far taller than a button
                    return Semantics(
                      button: true,
                      label: _expanded ? S.commentsReadLess : S.commentsReadMore,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _expanded = !_expanded),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ExcludeSemantics(child: text),
                            const SizedBox(height: 2),
                            Text(
                              _expanded ? S.commentsReadLess : S.commentsReadMore,
                              style: secondary?.copyWith(fontWeight: FontWeight.w600, color: p.link),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                if (c.likes != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(Icons.thumb_up_outlined, size: 14, color: p.textSecondary),
                        const SizedBox(width: 6),
                        Text(c.likes!, style: secondary),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The picture of a commenter, round; their initial in a tint while it is not there or cannot be had.
class _Photo extends StatelessWidget {
  const _Photo({required this.url, required this.name, required this.size});

  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = Avatar(name: name, size: size);
    if (url == null) return initial;
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Image(
          image: ResizeImage.resizeIfNeeded(
            (size * MediaQuery.devicePixelRatioOf(context)).round(),
            null,
            CachedCover(url!),
          ),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => initial,
          frameBuilder: (context, child, frame, sync) => sync || frame != null ? child : initial,
        ),
      ),
    );
  }
}

class _RepliesRow extends StatelessWidget {
  const _RepliesRow({required this.feed, required this.row});

  final CommentsFeed feed;
  final _RepliesButton row;

  @override
  Widget build(BuildContext context) {
    final c = row.comment;
    final n = c.replies;
    return _TextAction(
      indent: 48,
      label: row.open ? S.commentsHideReplies : (n == null ? S.commentsMoreReplies : S.commentReplies(n)),
      icon: row.open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
      loading: row.loading && !row.open || (row.open && row.loading && feed.replies[c.id]!.items.isEmpty),
      onTap: () => feed.toggleReplies(c),
    );
  }
}

/// A line of the colour of a link that does something when it is touched, 48 high.
class _TextAction extends StatelessWidget {
  const _TextAction({required this.indent, required this.label, required this.onTap, this.icon, this.loading = false});

  final double indent;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: loading ? null : onTap,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: EdgeInsets.only(left: indent),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: p.link, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 4),
                if (loading)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                else if (icon != null)
                  Icon(icon, size: 20, color: p.link),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The end of what was loaded: a spinner while the next page comes, and the way to comment, which is on YouTube.
class _FootRow extends StatelessWidget {
  const _FootRow({required this.feed, required this.videoId});

  final CommentsFeed feed;
  final String videoId;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      children: [
        if (feed.loadingMore)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          ),
        TextButton.icon(
          onPressed: () => launchUrl(
            Uri.https('www.youtube.com', '/watch', {'v': videoId}),
            mode: LaunchMode.externalApplication,
          ),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: p.link),
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: Text(S.commentsOpenOnYoutube),
        ),
      ],
    );
  }
}

/// The rows of the list as they are while the first page comes: a picture and two lines, still (a light sweeping over
/// them is a mask repainted at every frame, over a player that is playing).
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final bar = context.palette.textTertiary.withValues(alpha: 0.18);
    Widget block(double width, double height, {bool round = false}) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: bar,
        borderRadius: BorderRadius.circular(round ? height / 2 : 4),
      ),
    );
    return ExcludeSemantics(
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        children: [
          for (var i = 0; i < 6; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  block(32, 32, round: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        block(110, 10),
                        const SizedBox(height: 8),
                        block(double.infinity, 12),
                        const SizedBox(height: 6),
                        block(180, 12),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
