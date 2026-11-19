import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/error_log.dart';

import 'fake_backend.dart';

class _Broken extends StatelessWidget {
  const _Broken();

  @override
  Widget build(BuildContext context) => throw StateError('the cover is missing');
}

void main() {
  late FakeBackend backend;

  // The test binding sets its own error handler when the body starts, so this goes in the body, not in setUp
  void install() {
    final onError = FlutterError.onError;
    final onPlatformError = PlatformDispatcher.instance.onError;
    addTearDown(() {
      FlutterError.onError = onError;
      PlatformDispatcher.instance.onError = onPlatformError;
    });
    ErrorLog(backend.note).install();
  }

  setUp(() => backend = FakeBackend());

  testWidgets('a widget that throws while it is built leaves a line in the log', (tester) async {
    install();
    await tester.pumpWidget(const _Broken());
    tester.takeException();
    expect(backend.notes, hasLength(1));
    expect(backend.notes.single, startsWith('error: StateError: Bad state: the cover is missing @ '));
    expect(backend.notes.single, contains('_Broken.build'));
  });

  testWidgets('the same error again and again leaves one line', (tester) async {
    install();
    for (var i = 0; i < 100; i++) {
      FlutterError.reportError(FlutterErrorDetails(exception: StateError('again'), stack: StackTrace.current));
      tester.takeException();
    }
    expect(backend.notes.where((l) => l.contains('again')), hasLength(1));
  });

  test('different errors stop at the limit, with a line that says so', () {
    final log = ErrorLog(backend.note);
    for (var i = 0; i < 100; i++) {
      log.report('problem $i', null);
    }
    expect(backend.notes, hasLength(ErrorLog.maxLines + 1));
    expect(backend.notes.last, contains('more than ${ErrorLog.maxLines} errors'));
  });

  test('an error that no one catches is logged and not swallowed', () {
    install();
    final handled = PlatformDispatcher.instance.onError!(ArgumentError('late'), StackTrace.current);
    expect(handled, isFalse);
    expect(backend.notes.single, startsWith('error: ArgumentError: Invalid argument(s): late'));
  });

  test('a long message and a message over several lines become one short line', () {
    ErrorLog(backend.note).report('a\n   b ${'x' * 500}', null);
    final line = backend.notes.single;
    expect(line, isNot(contains('\n')));
    expect(line.length, lessThan(260));
  });
}
