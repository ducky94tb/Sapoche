import 'package:flutter/foundation.dart';

/// Puts the errors of the Dart side into the log of the app ("Copy log"), where nothing else would show them: in a
/// release build a widget that throws leaves a grey box and no trace. Nothing leaves the phone.
///
/// One line per error: `error: <type>: <message> @ <first frames of the stack>`. A line equal to the one before it is
/// left out (an error in every frame would push everything useful out of the log), and after [maxLines] lines in a run
/// a last line says so and the rest are dropped.
class ErrorLog {
  ErrorLog(this._note);

  static const maxLines = 30;
  static const _frames = 3;
  static const _messageChars = 200;

  final void Function(String line) _note;
  String? _last;
  int _written = 0;

  /// Hooks Flutter's and the platform's error callbacks. What they did before (print on the console) still happens.
  void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      report(details.exception, details.stack);
      previous?.call(details);
    };
    final previousAsync = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      report(error, stack);
      return previousAsync?.call(error, stack) ?? false;
    };
  }

  void report(Object error, StackTrace? stack) {
    if (_written > maxLines) return;
    final message = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
    final frames = (stack?.toString() ?? '')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .take(_frames)
        .join(' | ');
    final line =
        'error: ${error.runtimeType}: '
        '${message.length > _messageChars ? '${message.substring(0, _messageChars)}…' : message}'
        '${frames.isEmpty ? '' : ' @ $frames'}';
    if (line == _last) return;
    _last = line;
    if (++_written > maxLines) {
      _note('error: more than $maxLines errors in this run, the rest are not logged');
      return;
    }
    _note(line);
  }
}
