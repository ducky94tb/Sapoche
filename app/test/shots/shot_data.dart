import 'dart:convert';
import 'dart:io';

import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';

import '../fake_backend.dart';

/// The one set of songs, albums and people every screen of the picture set is drawn from, so that two runs on two
/// versions of the app show the same words and can be compared pixel by pixel. It is made to be awkward: long titles in
/// Vietnamese, a song with no length, one with no album, one with no plays.
const longVi = MusicTrack(
  videoId: 'long00000vi',
  title: 'Chúng Ta Của Hiện Tại (Phiên Bản Đặc Biệt Kèm Lời Bài Hát)',
  artist: 'Sơn Tùng M-TP',
  durMs: 305000,
  explicit: true,
  year: '2020',
  artistId: 'UCsontung',
  album: 'Chúng Ta Của Hiện Tại',
  albumId: 'MPREb_hientai',
  stats: '205M plays',
  isSong: true,
);
const noLength = MusicTrack(
  videoId: 'nolength000',
  title: 'No Length Yet',
  artist: 'Anna Lee',
  durMs: 0,
  artistId: 'UCanna',
  album: 'First Light',
  albumId: 'MPREb_first',
  isSong: true,
);
const noAlbum = MusicTrack(
  videoId: 'noalbum0000',
  title: 'Single With No Album',
  artist: 'Binh & The Long Named Band Of Friends',
  durMs: 187000,
  artistId: 'UCbinh',
  stats: '734K plays',
  isSong: true,
);
const hello = MusicTrack(
  videoId: 'hello000000',
  title: 'Hello',
  artist: 'Adele',
  durMs: 295000,
  explicit: true,
  year: '2015',
  artistId: 'UCadele',
  album: '25',
  albumId: 'MPREb_25',
  stats: '1.4B plays',
  isSong: true,
);
const clip = MusicTrack(
  videoId: 'clip0000000',
  title: 'Official Music Video',
  artist: 'Zen',
  durMs: 241000,
  artistId: 'UCzen',
  stats: '12M views',
);

const tracks = [longVi, noLength, noAlbum, hello, clip];

/// The first song as the radio of YouTube Music has it when it is a video: with its likes.
const longViVideo = MusicTrack(
  videoId: 'long00000vi',
  title: 'Chúng Ta Của Hiện Tại (Phiên Bản Đặc Biệt Kèm Lời Bài Hát)',
  artist: 'Sơn Tùng M-TP',
  durMs: 305000,
  artistId: 'UCsontung',
  stats: '205M views · 4.2M likes',
);

String _comments(String name) => File('test/fixtures/comments/$name').readAsStringSync();

/// What YouTube answers when the player asks for the comments of the song: its page, then the first page of them (the
/// pictures are of the first only, so any token is answered with it). The people in them are made up.
Future<String> shotComments(String body) async =>
    (jsonDecode(body) as Map).containsKey('videoId') ? _comments('watch_next.json') : _comments('page_top.json');

/// What YouTube answers of a song whose comments are turned off.
Future<String> shotCommentsOff(String body) async => _comments('watch_next_off.json');

/// What the player gets when YouTube cannot be reached.
Future<String> shotCommentsFail(String body) async => throw const SocketException('offline');

const albumPage = CollectionPage(
  id: 'MPREb_hientai',
  title: 'Chúng Ta Của Hiện Tại',
  kind: 'Album',
  year: '2020',
  owner: 'Sơn Tùng M-TP',
  ownerId: 'UCsontung',
  description: 'A single, released on its own.',
  stats: ['5 songs', '21 minutes'],
  tracks: tracks,
);

const artistPage = ArtistPage(
  id: 'UCsontung',
  name: 'Sơn Tùng M-TP',
  subscribers: '9.2M subscribers',
  description:
      'Nguyễn Thanh Tùng, known by his stage name Sơn Tùng M-TP, is a singer and songwriter. '
      'He began releasing songs online in 2011 and has been in the charts ever since.',
  topSongs: tracks,
  albums: [
    Release(
      id: 'MPREb_hientai',
      title: 'Chúng Ta Của Hiện Tại',
      subtitle: '2020',
    ),
    Release(id: 'MPREb_first', title: 'First Light', subtitle: '2017'),
  ],
  singles: [Release(id: 'MPREb_one', title: 'One Of Those', subtitle: '2021')],
  similar: [
    ArtistCard(id: 'UCanna', name: 'Anna Lee'),
    ArtistCard(id: 'UCbinh', name: 'Binh'),
  ],
);

const homeData = MusicHome(
  chips: [
    MoodChip(label: 'Relax', params: 'p-relax'),
    MoodChip(label: 'Workout', params: 'p-work'),
    MoodChip(label: 'Focus', params: 'p-focus'),
  ],
  shelves: [
    MusicShelf(title: 'Quick picks', tracks: tracks),
    MusicShelf(
      title: 'Featured playlists for you',
      playlists: [
        Release(id: 'PL1', title: 'Calm Evenings', subtitle: 'Playlist'),
        Release(id: 'PL2', title: 'Sơn Tùng M-TP Mix', subtitle: 'Mix'),
        Release(id: 'PL3', title: 'Morning Run', subtitle: 'Playlist'),
      ],
    ),
    MusicShelf(
      title: 'Albums for you',
      albums: [
        Release(
          id: 'MPREb_hientai',
          title: 'Chúng Ta Của Hiện Tại',
          subtitle: 'Sơn Tùng M-TP',
        ),
        Release(id: 'MPREb_first', title: 'First Light', subtitle: 'Anna Lee'),
        Release(id: 'MPREb_25', title: '25', subtitle: 'Adele'),
      ],
    ),
    MusicShelf(
      title: 'Similar artists',
      artists: [
        ArtistCard(id: 'UCanna', name: 'Anna Lee'),
        ArtistCard(id: 'UCbinh', name: 'Binh'),
        ArtistCard(id: 'UCadele', name: 'Adele'),
      ],
    ),
  ],
);

final searchData = SearchResults(
  chips: const [
    SearchChip(label: 'Songs', params: 'p-songs'),
    SearchChip(label: 'Albums', params: 'p-albums'),
  ],
  items: [
    for (final t in tracks)
      SearchItem(
        kind: t.isSong ? 'song' : 'video',
        id: t.videoId,
        title: t.title,
        subtitle: '${t.isSong ? 'Song' : 'Video'} · ${t.artist}',
        track: t,
      ),
    const SearchItem(
      kind: 'album',
      id: 'MPREb_hientai',
      title: 'Chúng Ta Của Hiện Tại',
      subtitle: 'Album · Sơn Tùng M-TP · 2020',
    ),
  ],
);

const lyricsData = Lyrics(
  lines: [
    LyricLine(0, 'Hello, it\'s me'),
    LyricLine(4000, 'I was wondering if after all these years'),
    LyricLine(9000, 'You\'d like to meet, to go over everything'),
    LyricLine(14000, 'They say that time\'s supposed to heal ya'),
  ],
);

/// A library as a person with taste would have it: liked songs, and songs played lately.
void fillLibrary(FakeBackend b) {
  final now = DateTime.now();
  b.likedSongs = [...tracks];
  b.recentSongs = [
    for (final (i, t) in tracks.indexed)
      // Days before today at noon, so that "Yesterday" stays yesterday whenever the pictures are drawn
      HistoryEntry(track: t, at: DateTime(now.year, now.month, now.day - 1 - i, 12), plays: 1 + i),
  ];
}

/// Outside a room, playing the first song of an album with two songs queued by hand ahead of the rest of the album.
RoomSnapshot splitQueue() => RoomSnapshot(
  phase: 'paused',
  index: 0,
  label: albumPage.title,
  queue: [
    for (final (i, t) in tracks.indexed)
      QueueEntry(
        id: 'q$i',
        videoId: t.videoId,
        title: t.title,
        artist: t.artist,
        durMs: t.durMs,
        explicit: t.explicit,
        year: t.year,
        addedBy: '',
        queued: i == 1 || i == 2,
      ),
  ],
);

/// Three people in a room, a queue of five and the first song playing.
RoomSnapshot busyRoom({String phase = 'playing', int index = 0, Link link = Link.connected, bool video = false}) {
  final base = sampleRoom(phase: phase, index: index, songs: 0);
  return RoomSnapshot(
    room: base.room,
    link: link,
    you: base.you,
    phase: phase,
    index: index,
    video: video,
    ownerId: 'me',
    members: const [
      Member(id: 'me', name: 'Anna', ready: true),
      Member(id: 'b', name: 'Bình', ready: true),
      Member(id: 'c', name: 'Cường', ready: true),
    ],
    queue: [
      for (final (i, t) in tracks.indexed)
        QueueEntry(
          id: 'q$i',
          videoId: t.videoId,
          title: t.title,
          artist: t.artist,
          durMs: t.durMs,
          explicit: t.explicit,
          year: t.year,
          addedBy: const ['me', 'b', 'c'][i % 3],
        ),
    ],
  );
}

/// A log that has everything the log page shows: the run before this one ended in a crash, quiet noise to fold, a few
/// warnings, an error with a stack, a mark with a note and a main line or two. Days are counted from today, so "Today" and
/// "Yesterday" are what the page says on any day.
List<String> shotLog({DateTime? now}) {
  final at = now ?? DateTime.now();
  String stamp(int daysAgo, String clock) {
    final d = at.subtract(Duration(days: daysAgo));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.month)}-${two(d.day)} $clock';
  }

  return [
    '${stamp(1, '21:14:02.120')} K [log] ---- process started ---- 1.54.0+116',
    '${stamp(1, '21:14:03.001')} I [play] loaded Chúng Ta Của Hiện Tại',
    '${stamp(1, '21:14:03.440')} K [room] connected to wss://sapoche.example/room',
    for (var i = 0; i < 12; i++) '${stamp(1, '21:14:${10 + i}.000')} D [sync] drift=${i * 7}ms smoothed=${i * 5}ms offset=3ms rtt=41ms',
    '${stamp(1, '21:31:20.500')} W [room] closed: 1006',
    '${stamp(1, '21:31:20.900')} W [room] reconnecting in 2000ms',
    '${stamp(1, '21:31:25.010')} E [crash] uncaught on main: java.lang.IllegalStateException: Player is released @ app.sapoche.PlaybackService.onUpdate:412 | app.sapoche.SapocheBridge.handle:871 | android.os.Handler.dispatchMessage:106',
    '${stamp(0, '08:02:11.300')} K [log] ---- process started ---- 1.54.1+117',
    '${stamp(0, '08:02:11.320')} E [exit] reason=CRASH importance=100 at=${stamp(1, '21:31:25')} description=',
    '${stamp(0, '08:02:12.000')} I [bridge] server set',
    for (var i = 0; i < 5; i++) '${stamp(0, '08:02:13.${100 + i}')} D [http] request position=${i * 262144} length=262144',
    '${stamp(0, '08:02:14.800')} K [room] connected to wss://sapoche.example/room',
    "${stamp(0, '08:02:15.200')} K [sync] following 'Chúng Ta Của Hiện Tại' from server time 1763880135200",
    for (var i = 0; i < 24; i++) '${stamp(0, '08:02:${16 + (i ~/ 2)}.${i.isEven ? '000' : '500'}')} D [sync] drift=${(i * 13) % 90}ms smoothed=${(i * 11) % 70}ms offset=3ms rtt=38ms',
    '${stamp(0, '08:09:40.250')} W [sync] stalled for 3100ms, 0ms buffered now',
    '${stamp(0, '08:09:40.260')} W [sync] weak network: the room may run ahead of this device',
    '${stamp(0, '08:09:48.000')} I [sync] network is good again',
    '${stamp(0, '08:12:03.100')} K [mark] the person marked this moment: music stopped for everyone',
    '${stamp(0, '08:12:04.500')} E [player] player error, recovering (#1): ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
    '${stamp(0, '08:12:09.000')} I [play] loaded Em Của Ngày Hôm Qua',
    for (var i = 0; i < 6; i++) '${stamp(0, '08:12:1$i.000')} D [sync] drift=${i * 9}ms smoothed=${i * 6}ms offset=3ms rtt=40ms',
    '${stamp(0, '08:14:30.000')} I [update] checking for a new version',
    '${stamp(0, '08:14:31.200')} I [update] up to date',
  ];
}
