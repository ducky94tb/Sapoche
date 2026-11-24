import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/log_line.dart';
import 'package:sapoche/data/log_model.dart';
import 'package:sapoche/data/room_controller.dart';

void main() {
  final fixture = jsonDecode(
    File('../native/sync/src/test/resources/diary_levels.json')
        .readAsStringSync(),
  ) as Map<String, dynamic>;

  test('levels are inferred as the shared fixture says (the same as Kotlin and Swift)', () {
    for (final row
        in (fixture['levels'] as List).cast<Map<String, dynamic>>()) {
      expect(
        Diary.infer(row['tag'] as String, row['message'] as String).letter,
        row['level'],
        reason: '[${row['tag']}] ${row['message']}',
      );
    }
  });

  test('the level is read back from a line as the shared fixture says', () {
    for (final row in (fixture['lines'] as List).cast<Map<String, dynamic>>()) {
      expect(
        Diary.levelOf(row['line'] as String)?.letter,
        row['level'],
        reason: row['line'] as String,
      );
    }
  });

  test('a line is built and parsed in the shared shape', () {
    final text = Diary.line(
      '11-23 14:02:11.123',
      LogLevel.warn,
      'room',
      'closed: 1006 ',
    );
    expect(text, '11-23 14:02:11.123 W [room] closed: 1006 ');
    final line = LogLine.parse(text, now: DateTime(2026, 11, 23, 15));
    expect(line.level, LogLevel.warn);
    expect(line.tag, 'room');
    expect(line.time, DateTime(2026, 11, 23, 14, 2, 11, 123));
    expect(line.group, LogGroup.room);
  });

  test(
    'a line of the old shape or a stray one is an ordinary line without a time',
    () {
      final line = LogLine.parse(
        '14:02:11.123 [play] old',
        now: DateTime(2026, 11, 23),
      );
      expect(line.level, LogLevel.info);
      expect(line.time, isNull);
      expect(line.tag, '?');
    },
  );

  test('a date that is ahead belongs to last year', () {
    final line = LogLine.parse(
      '12-30 10:00:00.000 I [a] b',
      now: DateTime(2026, 1, 2),
    );
    expect(line.time!.year, 2025);
  });

  test('a stamp the shape makes is read by the stamp it was made from', () {
    final t = DateTime(2026, 3, 4, 5, 6, 7, 89);
    expect(Diary.stamp(t), '03-04 05:06:07.089');
  });

  test('a tag that is not in the table falls in "other"', () {
    expect(LogGroup.of('never-heard-of'), LogGroup.other);
    expect(LogGroup.of('http'), LogGroup.play);
  });

  final now = DateTime(2026, 11, 23, 20);
  List<String> sample() => [
    '11-22 09:00:00.000 K [log] ---- process started ---- 1.54.0+116',
    '11-22 09:00:01.000 I [play] one',
    '11-22 09:00:02.000 E [crash] uncaught on main: boom',
    '11-23 08:00:00.000 K [log] ---- process started ---- 1.54.1+117',
    '11-23 08:00:00.100 E [exit] reason=CRASH importance=100 at=11-22 09:00:02 description=',
    '11-23 08:00:01.000 K [room] connected to wss://x',
    for (var i = 0; i < 5; i++)
      '11-23 08:00:0${2 + i}.000 D [sync] drift=${i}ms',
    '11-23 08:00:09.000 W [room] closed: 1006',
    '11-23 08:00:10.000 K [mark] the person marked this moment: it stopped',
    '11-23 08:00:11.000 I [play] after',
  ];

  test(
    'lines are cut into runs at each start, and a run says how it ended',
    () {
      final model = LogModel.parse(sample(), now: now);
      expect(model.runs.length, 2);
      expect(model.runs[0].version, '1.54.0+116');
      expect(model.runs[0].end, RunEnd.crash);
      expect(model.runs[1].end, RunEnd.running);
      expect(model.runs[1].version, '1.54.1+117');
    },
  );

  test('the digest counts the last run and knows the one before it failed', () {
    final digest = LogModel.parse(sample(), now: now).digest;
    expect(digest.errors, 1); // the [exit] line of the crash before
    expect(digest.warnings, 1);
    expect(digest.marks, 1);
    expect(digest.previousFailed, isTrue);
    expect(digest.clean, isFalse);
  });

  test('a log with nothing wrong is clean', () {
    final digest = LogModel.parse([
      '11-23 08:00:00.000 K [log] ---- process started ---- 1',
      '11-23 08:00:01.000 I [play] x',
    ], now: now).digest;
    expect(digest.clean, isTrue);
    expect(digest.previousFailed, isFalse);
  });

  test('the main mode shows E, W and K and says how many lines it hides between them', () {
    final rows = LogModel.parse(sample(), now: now).rows(mode: LogMode.main);
    final lines = rows.whereType<LineRow>().map((r) => r.line.message).toList();
    expect(lines.any((m) => m.contains('drift=')), isFalse);
    expect(lines, contains('closed: 1006'));
    final hidden = rows.whereType<HiddenRow>().toList();
    expect(hidden.map((h) => h.count), contains(5));
  });

  test('quiet lines of one tag fold into a row that opens by its key', () {
    final model = LogModel.parse(sample(), now: now);
    final closed = model.rows(mode: LogMode.detail);
    final fold = closed.whereType<FoldRow>().single;
    expect(fold.lines.length, 5);
    final open = model.rows(mode: LogMode.detail, open: {fold.key});
    expect(open.whereType<FoldRow>(), isEmpty);
    expect(
      open
          .whereType<LineRow>()
          .where((r) => r.line.message.startsWith('drift='))
          .length,
      5,
    );
  });

  test('errors, warnings and marks are never folded', () {
    final raw = [
      '11-23 08:00:00.000 K [log] ---- process started ---- 1',
      for (var i = 0; i < 4; i++) '11-23 08:00:0$i.000 W [room] closed: $i',
    ];
    final rows = LogModel.parse(raw, now: now).rows(mode: LogMode.all);
    expect(rows.whereType<FoldRow>(), isEmpty);
    expect(rows.whereType<LineRow>().length, 5);
  });

  test('a group and a search narrow the rows, and the day separators come with the lines', () {
    final model = LogModel.parse(sample(), now: now);
    final rooms = model.rows(mode: LogMode.all, groups: {LogGroup.room});
    expect(
      rooms.whereType<LineRow>().every(
        (r) => r.line.group == LogGroup.room || r.line.isMark,
      ),
      isTrue,
    );
    final found = model.rows(mode: LogMode.detail, query: 'DRIFT=3');
    expect(found.whereType<LineRow>().single.line.message, 'drift=3ms');
    expect(model.rows(mode: LogMode.all).whereType<DayRow>().length, 2);
  });

  test('the lines around one are the ones before and after it', () {
    final model = LogModel.parse(sample(), now: now);
    expect(model.around(5, count: 2).length, 5);
    expect(model.around(0, count: 2).length, 3);
  });

  test('the short form keeps the main lines and the tail, in order', () {
    final lines = [
      for (var i = 0; i < 400; i++)
        i == 3
            ? '11-23 08:00:00.000 E [crash] early failure'
            : '11-23 08:00:00.000 I [play] n$i',
    ];
    final short = RoomController.shortLog(lines);
    expect(short.length, RoomController.shortTail + 1);
    expect(short.first, contains('early failure'));
    expect(short.last, contains('n399'));
  });
}
