import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The rule at the head of `Motion` ("every motion of the interface that is not the person's finger asks here") kept
/// by a scan of `lib/`: a sheet, a dialog or a menu that opens without asking, or an implicit animation with a duration
/// of its own, would go on moving on a phone set to Light or Minimal effects, and nobody would notice.

/// Calls that are left out, and why. A key is the file and a word of the call.
const _exceptions = <String, String>{
  'ui/photo_viewer.dart AnimatedContainer':
      'the picture follows the finger as it is pulled down',
  'ui/chat_sheet.dart AnimatedContainer(\n            duration: _dragging':
      'a message follows the finger as it is swiped, and snaps back when let go',
};

/// The text from the `(` at [open] to its matching `)`.
String _call(String source, int open) {
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    final c = source[i];
    if (c == '(') depth++;
    if (c == ')' && --depth == 0) return source.substring(open, i + 1);
  }
  return source.substring(open);
}

List<File> _sources() => [
  for (final entity in Directory('lib').listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity,
];

String _where(File file, String source, int at) =>
    '${file.path.replaceFirst('lib/', '')}:${'\n'.allMatches(source.substring(0, at)).length + 1}';

void main() {
  test('every sheet, dialog and menu asks Motion how to open', () {
    final rules = {
      RegExp(r'\bshowModalBottomSheet(?:<[^>(]*>)?\('): 'sheetAnimationStyle',
      RegExp(r'\bshowDialog(?:<[^>(]*>)?\('): 'animationStyle',
      RegExp(r'\bshowMenu(?:<[^>(]*>)?\('): 'popUpAnimationStyle',
      RegExp(r'\bPopupMenuButton(?:<[^>(]*>)?\('): 'popUpAnimationStyle',
    };
    final lacking = <String>[];
    for (final file in _sources()) {
      final source = file.readAsStringSync();
      for (final MapEntry(key: pattern, value: argument) in rules.entries) {
        for (final match in pattern.allMatches(source)) {
          if (!_call(source, match.end - 1).contains(argument)) {
            lacking.add('${_where(file, source, match.start)} lacks $argument');
          }
        }
      }
    }
    expect(lacking, isEmpty, reason: lacking.join('\n'));
  });

  test('no implicit animation has a duration of its own', () {
    final pattern = RegExp(
      r'\b(?:Animated[A-Z]\w*|TweenAnimationBuilder(?:<[^>(]*>)?)\(',
    );
    final own = RegExp(r'duration:\s*const Duration\(');
    final lacking = <String>[];
    for (final file in _sources()) {
      final source = file.readAsStringSync();
      final path = file.path.replaceFirst('lib/', '');
      for (final match in pattern.allMatches(source)) {
        final call = _call(source, match.end - 1);
        if (!own.hasMatch(call)) continue;
        final excused = _exceptions.keys.any((key) {
          final parts = key.split(' ');
          final head = key.substring(parts.first.length + 1);
          return path == parts.first &&
              (source.substring(match.start).startsWith(head) ||
                  call.contains(head.split('(').last));
        });
        if (!excused) {
          lacking.add(
            '${_where(file, source, match.start)} ${match.group(0)} has its own duration',
          );
        }
      }
    }
    expect(lacking, isEmpty, reason: lacking.join('\n'));
  });
}
