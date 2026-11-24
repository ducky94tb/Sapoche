import 'log_line.dart';

/// How a run of the app ended, as far as the log can tell.
enum RunEnd { running, normal, crash, anr, killed }

/// The lines between two starts of the app.
class LogRun {
  LogRun(this.lines, {required this.end});

  final List<LogLine> lines;
  final RunEnd end;

  LogLine get first => lines.first;

  DateTime? get started => first.time;

  /// The version the start line names ("1.54.1+117"), or null.
  String? get version {
    final m = RegExp(r'---- process started ---- (\S+)').firstMatch(first.message);
    return m?[1];
  }

  int count(LogLevel level) => lines.where((l) => l.level == level).length;

  int get marks => lines.where((l) => l.isMark).length;

  bool get failed => end == RunEnd.crash || end == RunEnd.anr;
}

/// What the viewer shows at the top: whether there is anything wrong, without scrolling.
class LogDigest {
  const LogDigest({required this.errors, required this.warnings, required this.marks, required this.previousFailed});

  final int errors;
  final int warnings;
  final int marks;

  /// The run before the last one ended in a crash, an ANR or was killed.
  final bool previousFailed;

  bool get clean => errors == 0 && warnings == 0;
}

/// How much of the log is shown.
enum LogMode {
  /// Errors, warnings, milestones and marks.
  main,
  all,

  /// Everything, noise too.
  detail;

  bool shows(LogLine line) => switch (this) {
        main => line.level.index <= LogLevel.main.index,
        all => line.level != LogLevel.detail,
        detail => true,
      };
}

sealed class LogRow {
  const LogRow();
}

/// The top of a run.
class RunRow extends LogRow {
  const RunRow(this.run, this.index);
  final LogRun run;

  /// The place of the run in the list, newest last.
  final int index;
}

class DayRow extends LogRow {
  const DayRow(this.day);
  final DateTime day;
}

class LineRow extends LogRow {
  const LineRow(this.line, this.at);
  final LogLine line;

  /// The place of the line in the whole log, to find it again in another mode.
  final int at;
}

/// Quiet lines in a row with the same tag, as one row; [open] shows them.
class FoldRow extends LogRow {
  const FoldRow(this.lines, this.key);
  final List<LineRow> lines;

  /// Stays the same while the same lines fold together, so that a row that was opened stays open.
  final String key;

  LogLine get first => lines.first.line;
  LogLine get last => lines.last.line;
}

/// Lines the mode leaves out between two lines it shows: touching it opens them.
class HiddenRow extends LogRow {
  const HiddenRow(this.count, this.at);
  final int count;

  /// The place in the whole log of the first line hidden.
  final int at;
}

class LogModel {
  LogModel._(this.lines, this.runs);

  /// Every line, oldest first.
  final List<LogLine> lines;
  final List<LogRun> runs;

  static const foldFrom = 3;

  factory LogModel.parse(List<String> raw, {DateTime? now}) {
    final lines = [for (final r in raw) LogLine.parse(r, now: now)];
    final groups = <List<LogLine>>[];
    for (final line in lines) {
      if (line.isStart || groups.isEmpty) {
        groups.add([line]);
      } else {
        groups.last.add(line);
      }
    }
    final runs = <LogRun>[];
    for (var i = 0; i < groups.length; i++) {
      final next = i + 1 < groups.length ? groups[i + 1] : null;
      runs.add(LogRun(groups[i], end: _endOf(groups[i], next)));
    }
    return LogModel._(lines, runs);
  }

  /// A crash is told in the run that crashed (Android) or in the run after it (the system's word, MetricKit).
  static RunEnd _endOf(List<LogLine> run, List<LogLine>? next) {
    bool hasExit(String reason) =>
        (next ?? const <LogLine>[]).any((l) => l.tag == 'exit' && l.message.contains('reason=$reason'));
    if (run.any((l) => l.tag == 'crash') || hasExit('CRASH') || hasExit('CRASH_NATIVE')) return RunEnd.crash;
    if (hasExit('ANR')) return RunEnd.anr;
    if ((next ?? const <LogLine>[]).any((l) => l.tag == 'diagnostic')) return RunEnd.crash;
    if (hasExit('LOW_MEMORY') || hasExit('SIGNALED') || hasExit('EXCESSIVE_RESOURCE_USAGE')) return RunEnd.killed;
    return next == null ? RunEnd.running : RunEnd.normal;
  }

  LogRun? get last => runs.isEmpty ? null : runs.last;

  /// The counts of the last run, and whether the one before it failed.
  LogDigest get digest {
    final run = last;
    return LogDigest(
      errors: run?.count(LogLevel.error) ?? 0,
      warnings: run?.count(LogLevel.warn) ?? 0,
      marks: run?.marks ?? 0,
      previousFailed: runs.length > 1 && runs[runs.length - 2].failed,
    );
  }

  bool matches(LogLine line, {Set<LogGroup> groups = const {}, String query = ''}) {
    if (groups.isNotEmpty && !groups.contains(line.group) && !line.isMark) return false;
    if (query.isNotEmpty && !line.raw.toLowerCase().contains(query.toLowerCase())) return false;
    return true;
  }

  /// The rows of the list for a mode and filters. A line of an error, a warning or a mark is never folded; noise in a row
  /// with the same tag is, from [foldFrom] lines, unless its key is in [open] or [fold] is false (a search). In [LogMode.main] the lines the mode leaves
  /// out show up as a [HiddenRow].
  List<LogRow> rows({
    LogMode mode = LogMode.main,
    Set<LogGroup> groups = const {},
    String query = '',
    Set<String> open = const {},
    Set<LogLevel> levels = const {},
    bool showDays = true,
    bool fold = true,
  }) {
    final rows = <LogRow>[];
    var at = 0;
    DateTime? day;
    for (var r = 0; r < runs.length; r++) {
      final run = runs[r];
      rows.add(RunRow(run, r));
      day = null;
      var hidden = 0;
      var hiddenAt = 0;
      var pending = <LineRow>[];

      void flushPending() {
        if (pending.isEmpty) return;
        if (fold && pending.length >= foldFrom) {
          final key = '${pending.first.at}-${pending.length}';
          if (open.contains(key)) {
            rows.addAll(pending);
          } else {
            rows.add(FoldRow(pending, key));
          }
        } else {
          rows.addAll(pending);
        }
        pending = <LineRow>[];
      }

      void flushHidden() {
        if (hidden > 0) rows.add(HiddenRow(hidden, hiddenAt));
        hidden = 0;
      }

      for (final line in run.lines) {
        final here = at++;
        final shown = mode.shows(line) && (levels.isEmpty || levels.contains(line.level)) && matches(line, groups: groups, query: query);
        if (!shown) {
          if (mode == LogMode.main && query.isEmpty && groups.isEmpty && levels.isEmpty) {
            flushPending();
            if (hidden == 0) hiddenAt = here;
            hidden++;
          }
          continue;
        }
        flushHidden();
        final time = line.time;
        if (showDays && time != null) {
          final d = DateTime(time.year, time.month, time.day);
          if (d != day) {
            flushPending();
            rows.add(DayRow(d));
            day = d;
          }
        }
        final row = LineRow(line, here);
        final quiet = line.level == LogLevel.info || line.level == LogLevel.detail;
        if (quiet && pending.isNotEmpty && pending.last.line.tag == line.tag) {
          pending.add(row);
        } else {
          flushPending();
          if (quiet) {
            pending.add(row);
          } else {
            rows.add(row);
          }
        }
      }
      flushPending();
      flushHidden();
    }
    return rows;
  }

  /// Lines around [at] in the whole log, [count] on each side.
  List<LogLine> around(int at, {int count = 10}) =>
      lines.sublist((at - count).clamp(0, lines.length), (at + count + 1).clamp(0, lines.length));
}
