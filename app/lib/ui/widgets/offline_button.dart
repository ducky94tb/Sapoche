import 'package:flutter/material.dart';

import '../../data/library_controller.dart';
import '../../data/models.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import 'download_actions.dart';
import 'play_row.dart';
import 'motion.dart';

/// The round button beside Play that keeps a playlist or a folder on the phone, as Spotify's does: off (an arrow), coming
/// (a ring that fills by the songs on the phone), or all there (an arrow on a disc of the accent colour). Switched on, the
/// songs it has come at once and the ones added later by themselves; switched off, the person chooses whether the songs
/// stay. A browser downloads nothing, so the caller does not show it there.
class OfflineButton extends StatefulWidget {
  const OfflineButton.playlist(SavedPlaylist this.playlist, {super.key}) : folder = null;
  const OfflineButton.folder(PlaylistFolder this.folder, {super.key}) : playlist = null;

  final SavedPlaylist? playlist;
  final PlaylistFolder? folder;

  @override
  State<OfflineButton> createState() => _OfflineButtonState();
}

class _OfflineButtonState extends State<OfflineButton> {
  /// The songs of the folder's playlists, read again when they change (a song added or taken away, a playlist put in).
  List<Track> _folderSongs = const [];
  String _read = '';

  /// A playlist's songs are those of its page, which the library keeps up to date while it is open.
  List<Track> _songs(LibraryController library) => switch (widget.playlist) {
    final playlist? => library.playlistTracks(playlist.id),
    null => _folderSongs,
  };

  Future<void> _load(List<SavedPlaylist> playlists, String key) async {
    _read = key;
    final lists = await AppScope.of(context).library.songsOfPlaylists([for (final p in playlists) p.id]);
    if (!mounted || key != _read) return;
    final seen = <String>{};
    setState(() => _folderSongs = [for (final list in lists) ...list.where((t) => seen.add(t.videoId))]);
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    final p = context.palette;
    if (widget.folder case final folder?) {
      final playlists = library.playlistsIn(folder.id);
      // A song taken out and another put in leaves the count as it was, but moves the time of the change
      final key = [for (final pl in playlists) '${pl.id}:${pl.count}:${pl.updatedAt}:${pl.thumbs.join()}'].join(',');
      if (key != _read) _load(playlists, key);
    }
    return ValueListenableBuilder(
      valueListenable: library.downloadList,
      builder: (context, downloads, child) {
        final on = switch (widget.folder) {
          final folder? => folder.offline,
          null => library.isKept(widget.playlist!),
        };
        // What is to come: a song on the phone already as a file is there, and one YouTube will not give out never comes
        final wanted = [
          for (final t in _songs(library))
            if (!t.isLocal && library.downloadState(t.videoId) != DownloadState.unavailable) t,
        ];
        final done = wanted.where((t) => library.downloadState(t.videoId) == DownloadState.done).length;
        // The songs of a playlist that has some are read as its page opens: until then there is nothing to say it is all there
        final unread = widget.playlist != null && _songs(library).isEmpty && widget.playlist!.count > 0;
        final complete = done == wanted.length && !unread;
        const arrow = Icon(Icons.arrow_downward_rounded);
        if (!on) {
          return IconButton(onPressed: () => _switchOn(wanted), tooltip: S.download, style: roundButtonStyle(context), icon: arrow);
        }
        if (complete) {
          return IconButton(
            onPressed: _switchOff,
            tooltip: S.downloadedSongs,
            style: IconButton.styleFrom(
              fixedSize: const Size.square(52),
              backgroundColor: p.primary,
              foregroundColor: p.onPrimary,
              shape: const CircleBorder(),
            ),
            icon: arrow,
          );
        }
        return Stack(
          alignment: Alignment.center,
          children: [
            IconButton(
              onPressed: _switchOff,
              tooltip: S.downloadingOf(done, wanted.length),
              style: roundButtonStyle(context).copyWith(foregroundColor: WidgetStatePropertyAll(p.primary)),
              icon: arrow,
            ),
            IgnorePointer(
              child: SizedBox.square(
                dimension: 52,
                child: CircularProgressIndicator(
                  value: wanted.isEmpty ? null : done / wanted.length,
                  strokeWidth: 2.5,
                  color: p.primary,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _switchOn(List<Track> wanted) async {
    final library = AppScope.of(context).library;
    final cellular = (await library.storage())?.offlineCellular ?? false;
    if (!mounted) return;
    // What is on the phone already is left alone; the rest comes now, with the progress and Cancel of any download.
    // Asked for before the switch is set: set first, the run that fetches kept songs by themselves would take a song
    // that the run asked for here takes as well
    final missing = [
      for (final t in wanted)
        if (library.downloadState(t.videoId) != DownloadState.done) t,
    ];
    await startDownload(context, missing, allowMetered: cellular, kept: true);
    switch (widget.folder) {
      case final folder?:
        await library.setFolderOffline(folder.id, true);
      case null:
        await library.setPlaylistOffline(widget.playlist!.id, true);
    }
  }

  Future<void> _switchOff() async {
    final library = AppScope.of(context).library;
    final messenger = ScaffoldMessenger.of(context);
    final playlist = widget.playlist;
    final folder = widget.folder;
    // A playlist kept by its folder follows the folder: there is no "on, but not this one"
    final byFolder = playlist == null ? null : library.keepingFolder(playlist);
    if (byFolder != null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.keptByFolder(byFolder.name))));
      return;
    }
    final n = await library.offlineRemovable(playlistId: playlist?.id, folderId: folder?.id);
    if (!mounted) return;
    bool? remove = false;
    if (n > 0) {
      remove = await showDialog<bool>(
        context: context,
        animationStyle: Motion.dialog(context),
        builder: (context) => AlertDialog(
          title: Text(folder == null ? S.stopOfflinePlaylist : S.stopOfflineFolder),
          content: Text(S.stopOfflineBody(n)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.keepSongs)),
            TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.delete)),
          ],
        ),
      );
    }
    if (remove == null) return;
    if (folder != null) {
      await library.setFolderOffline(folder.id, false, remove: remove);
    } else {
      await library.setPlaylistOffline(playlist!.id, false, remove: remove);
    }
  }
}
