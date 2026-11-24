/// How serious a line of the diary is. Mirrors `Diary.kt` and `Diary.swift`; the three read the same `diary_levels.json`.
enum LogLevel {
  error('E'),
  warn('W'),

  /// A milestone: the app started, a room was joined, the song changed.
  main('K'),
  info('I'),

  /// Noise kept in the file and hidden by default: a line every second, a request, an estimate.
  detail('D');

  const LogLevel(this.letter);
  final String letter;

  static LogLevel? ofLetter(String letter) {
    for (final level in values) {
      if (level.letter == letter) return level;
    }
    return null;
  }
}

/// The shared shape of a line: `MM-dd HH:mm:ss.SSS L [tag] message`, the same on Android, iOS and the web.
class Diary {
  const Diary._();

  static const _stampLength = 18; // MM-dd HH:mm:ss.SSS

  static String line(String stamp, LogLevel level, String tag, String message) => '$stamp ${level.letter} [$tag] $message';

  /// The stamp of [time], as a line starts.
  static String stamp(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}.${time.millisecond.toString().padLeft(3, '0')}';
  }

  /// The level written in [line], or null for a line of the old shape or a stray one.
  static LogLevel? levelOf(String line) {
    if (line.length <= _stampLength + 4) return null;
    if (line[2] != '-' || line[5] != ' ' || line[_stampLength] != ' ' || line[_stampLength + 2] != ' ' || line[_stampLength + 3] != '[') {
      return null;
    }
    return LogLevel.ofLetter(line[_stampLength + 1]);
  }

  static const _detailTags = {'http'};
  static const _detailPrefixes = ['drift='];
  static const _detailParts = ['bandwidth estimate'];
  static const _errorTags = {'crash', 'error', 'diagnostic'};
  static const _errorParts = ['player error', 'uncaught', 'the player failed'];
  static const _warnParts = [
    'failed', 'could not', 'giving up', 'did not load', 'weak network', 'stalled', 'no answer', 'rejected', 'refused',
    'reconnecting', 'closed:', 'server error', 'unparsable', 'found nothing', 'no radio',
  ];
  static const _mainPrefixes = [
    'connected to ', 'listening on my own', 'back to listening on my own', 'following the room again', 'advanced locally to',
    "following '", "prepared '", '---- process started', 'the sound was taken', 'the interruption', 'the output changed',
    'the output went away',
  ];

  /// The level of a line written without one. First match wins, from the loudest.
  static LogLevel infer(String tag, String message) {
    final text = message.toLowerCase();
    if (_detailTags.contains(tag) || _detailPrefixes.any(text.startsWith) || _detailParts.any(text.contains)) return LogLevel.detail;
    if (_errorTags.contains(tag) || _errorParts.any(text.contains)) return LogLevel.error;
    if (tag == 'exit') {
      return message.contains('reason=CRASH') || message.contains('reason=ANR') ? LogLevel.error : LogLevel.warn;
    }
    if (_warnParts.any(text.contains)) return LogLevel.warn;
    if (_mainPrefixes.any(text.startsWith)) return LogLevel.main;
    return LogLevel.info;
  }
}

/// What a line is about, for the chips of the viewer. The table is here alone: a tag that is not in it falls in [other], so
/// the native sides need no change for a new tag.
enum LogGroup {
  play,
  room,
  network,
  system,
  update,
  ui,
  other;

  static const _tags = <String, LogGroup>{
    'play': play, 'player': play, 'port': play, 'load': play, 'resolve': play, 'stream': play, 'stall': play, 'cache': play,
    'http': play, 'eq': play, 'volume': play, 'audio': play, 'video': play, 'picture': play, 'scrobble': play,
    'suggest': play, 'suggestions': play, 'download': play, 'library': play, 'media': play, 'local': play,
    'sync': room, 'room': room, 'chat': room,
    'net': network,
    'log': system, 'service': system, 'session': system, 'awake': system, 'heat': system, 'exit': system, 'crash': system,
    'diagnostic': system, 'app': system, 'widget': system, 'widgets': system, 'bridge': system,
    'update': update,
    'ui': ui, 'display': ui, 'error': ui, 'mark': ui,
  };

  static LogGroup of(String tag) => _tags[tag] ?? other;
}

/// One line of the diary, read back.
class LogLine {
  const LogLine({required this.raw, required this.level, required this.tag, required this.message, this.time});

  final String raw;
  final LogLevel level;
  final String tag;
  final String message;

  /// When it was written; null for a line of the old shape. The line holds no year: the nearest one that is not in the future.
  final DateTime? time;

  LogGroup get group => LogGroup.of(tag);

  bool get isMark => tag == 'mark';

  bool get isStart => tag == 'log' && message.startsWith('---- process started');

  static final _shape = RegExp(r'^(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d\d\d) ([EWKID]) \[([^\]]*)\] ?(.*)$', dotAll: true);

  /// Reads [raw]; a line that is not of the shape becomes an ordinary line with no time and the tag `?`.
  static LogLine parse(String raw, {DateTime? now}) {
    final m = _shape.firstMatch(raw);
    if (m == null) return LogLine(raw: raw, level: LogLevel.info, tag: '?', message: raw);
    final at = now ?? DateTime.now();
    var time = DateTime(at.year, int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!), int.parse(m[4]!), int.parse(m[5]!), int.parse(m[6]!));
    if (time.isAfter(at.add(const Duration(days: 1)))) {
      time = DateTime(at.year - 1, time.month, time.day, time.hour, time.minute, time.second, time.millisecond);
    }
    return LogLine(raw: raw, level: LogLevel.ofLetter(m[7]!)!, tag: m[8]!, message: m[9]!, time: time);
  }
}
