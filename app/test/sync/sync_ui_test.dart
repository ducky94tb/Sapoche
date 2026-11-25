import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/sync/sync_controller.dart';
import 'package:sapoche/strings.dart';

import '../pump_app.dart';
import 'sync_harness.dart';

void main() {
  late Phone phone;

  Future<void> open(WidgetTester tester, {bool withSync = true}) async {
    phone = Phone('Test', FakeServer(), Clock());
    await pumpApp(tester, sync: withSync ? phone.sync : null);
  }

  testWidgets('without an engine the settings keep the backup file only', (tester) async {
    await open(tester, withSync: false);
    await openTopic(tester, 'backup');
    expect(find.text(S.syncTurnOn), findsNothing);
    expect(find.text(S.backupSave), findsOneWidget);
  });

  testWidgets('turning sync on shows the recovery code, which stays until it is kept', (tester) async {
    await open(tester);
    await openTopic(tester, 'backup');
    expect(find.text(S.syncTurnOn), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sync-turn-on')));
    await tester.pumpAndSettle();
    expect(phone.sync.enabled, isTrue);
    expect(find.byKey(const ValueKey('sync-code')), findsOneWidget);
    expect(find.text(phone.sync.key!.display), findsOneWidget);
    // It cannot be closed by a tap beside it
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-code')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sync-saved')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-code')), findsNothing);
    expect(phone.sync.recoverySaved, isTrue);
    expect(find.byKey(const ValueKey('sync-status')), findsOneWidget);
    expect(find.text(S.syncNotSaved), findsNothing);
  });

  testWidgets('a code that is no code is refused', (tester) async {
    await open(tester);
    await openTopic(tester, 'backup');
    await tester.tap(find.byKey(const ValueKey('sync-use-code')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not a code');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text(S.syncBadCode), findsOneWidget);
    expect(phone.sync.enabled, isFalse);
  });

  testWidgets('turning sync off asks about the copy on the server', (tester) async {
    await open(tester);
    await phone.sync.enable();
    await openTopic(tester, 'backup');
    await tester.tap(find.byKey(const ValueKey('sync-turn-off')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(S.syncDeleteCopy));
    await tester.pumpAndSettle();
    expect(phone.sync.enabled, isFalse);
    expect(phone.server.blobs, isEmpty);
    expect(find.text(S.syncTurnOn), findsOneWidget);
  });

  testWidgets('the library offers sync once and stops when sent away', (tester) async {
    await open(tester);
    await phone.sync.load();
    await tester.tap(find.text(S.tabLibrary));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-card')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sync-card-later')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-card')), findsNothing);
    expect(phone.sync.offerCard, isFalse);
    expect(phone.state.text, contains('"cardDismissed":true'));
    expect(phone.sync.phase, SyncPhase.off);
  });
}
