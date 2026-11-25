import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../data/sync/sync_client.dart';
import '../data/sync/sync_controller.dart';
import '../data/sync/sync_crypto.dart';
import '../data/sync/sync_merge.dart' show SyncRefused;
import '../strings.dart';
import '../theme/theme.dart';
import 'widgets/motion.dart';
import 'widgets/qr_code_view.dart';
import 'widgets/text_dialog.dart';

/// What a failed sync says, in a few words.
String syncFailureText(SyncFailure? failure) => switch (failure) {
  SyncFailure.offline => S.syncOffline,
  SyncFailure.unauthorized || SyncFailure.forbidden => S.syncRefusedKey,
  SyncFailure.unavailable => S.syncUnavailable,
  SyncFailure.tooBig => S.syncTooBig,
  SyncFailure.tooOften => S.syncTooOften,
  SyncFailure.missing => S.syncNoLibrary,
  _ => S.syncFailed,
};

void _say(BuildContext context, String text) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(text)));

/// The first run: a library of its own is started, then the recovery code is shown and cannot be put off.
Future<void> startSync(BuildContext context, SyncController sync) async {
  final failure = await sync.enable();
  if (!context.mounted) return;
  if (failure != null) {
    _say(context, syncFailureText(failure));
    return;
  }
  await showRecoveryCode(context, sync, required: true);
}

/// Joins the library of a code typed or pasted, or of [key] when a link brought it.
Future<void> joinSync(BuildContext context, SyncController sync, {SyncKey? key}) async {
  if (key == null) {
    final text = await showTextDialog(
      context,
      title: S.syncEnterCode,
      hint: S.syncCodeHint,
      maxLength: 120,
      capitalization: TextCapitalization.characters,
    );
    if (text == null || text.trim().isEmpty || !context.mounted) return;
    key = SyncKey.fromText(text);
    if (key == null) {
      _say(context, S.syncBadCode);
      return;
    }
  }
  final ok = await showDialog<bool>(
    context: context,
    animationStyle: Motion.dialog(context),
    builder: (context) => AlertDialog(
      content: Text(S.syncMergeQuestion),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.cancel)),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.syncMerge)),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final failure = await sync.join(key);
  if (context.mounted && failure != null) _say(context, syncFailureText(failure));
}

/// The key as a code to keep. With [required] it stays until it was copied, shared or marked as kept.
Future<void> showRecoveryCode(BuildContext context, SyncController sync, {bool required = false}) {
  final key = sync.key;
  if (key == null) return Future.value();
  return showDialog<void>(
    context: context,
    barrierDismissible: !required,
    animationStyle: Motion.dialog(context),
    builder: (context) => PopScope(
      canPop: !required,
      child: AlertDialog(
        title: Text(S.syncRecovery),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                key.display,
                key: const ValueKey('sync-code'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(letterSpacing: 1),
              ),
              const SizedBox(height: 12),
              Text(S.syncRecoveryHelp, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.palette.text)),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('sync-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: key.display));
              await sync.markSaved();
              if (context.mounted) _say(context, S.syncCopied);
            },
            child: Text(S.syncCopy),
          ),
          TextButton(
            onPressed: () async {
              await SharePlus.instance.share(ShareParams(text: key.display));
              await sync.markSaved();
            },
            child: Text(S.syncShare),
          ),
          TextButton(
            key: const ValueKey('sync-saved'),
            onPressed: () async {
              await sync.markSaved();
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(S.syncSaved),
          ),
          if (!required) TextButton(onPressed: () => Navigator.pop(context), child: Text(S.close)),
        ],
      ),
    ),
  );
}

/// The key as a QR code and as a code, for another device.
Future<void> showAddDevice(BuildContext context, SyncController sync) {
  final key = sync.key;
  if (key == null) return Future.value();
  return showDialog<void>(
    context: context,
    animationStyle: Motion.dialog(context),
    builder: (context) => AlertDialog(
      title: Text(S.syncAddDevice),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrCodeView(data: key.link, size: 200),
            const SizedBox(height: 12),
            SelectableText(key.display, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Text(S.syncAddHelp, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: context.palette.text)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: key.link));
            if (context.mounted) _say(context, S.syncCopied);
          },
          child: Text(S.syncCopy),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(S.close)),
      ],
    ),
  );
}

/// The older copies the server kept: one is chosen and put back everywhere.
Future<void> showSyncVersions(BuildContext context, SyncController sync) async {
  final List<SyncVersion> versions;
  try {
    versions = await sync.versions();
  } on SyncException catch (e) {
    if (context.mounted) _say(context, syncFailureText(e.failure));
    return;
  }
  if (!context.mounted) return;
  if (versions.isEmpty) {
    _say(context, S.syncNoCopies);
    return;
  }
  final chosen = await showModalBottomSheet<SyncVersion>(
    context: context,
    sheetAnimationStyle: Motion.sheet(context),
    builder: (context) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final v in versions)
            ListTile(
              key: ValueKey('sync-version-${v.at}'),
              leading: const Icon(Icons.history_rounded),
              title: Text(_when(v.at)),
              onTap: () => Navigator.pop(context, v),
            ),
        ],
      ),
    ),
  );
  if (chosen == null || !context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    animationStyle: Motion.dialog(context),
    builder: (context) => AlertDialog(
      content: Text(S.syncRestoreQuestion(_when(chosen.at))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.cancel)),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.syncRestoreDo)),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final failure = await sync.restoreVersion(chosen);
  if (context.mounted && failure != null) _say(context, syncFailureText(failure));
}

/// A short date and time, like `25/11 14:02`.
String _when(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
}

/// The time of a sync for the status line: the hour today, the day and hour before.
String syncTime(DateTime t) => _when(t.millisecondsSinceEpoch).substring(DateUtils.isSameDay(t, DateTime.now()) ? 6 : 0);

/// Asks to go on with a change that takes a lot away; true when the person agrees.
Future<bool> askSyncRefused(BuildContext context, SyncRefused refused) async {
  final ok = await showDialog<bool>(
    context: context,
    animationStyle: Motion.dialog(context),
    builder: (context) => AlertDialog(
      title: Text(S.syncPaused(refused.loss.likes, refused.loss.playlists)),
      content: Text(S.syncPausedQuestion(refused.fromHere)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.cancel)),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.syncContinue)),
      ],
    ),
  );
  return ok == true;
}

/// Turn sync off: the library stays; the copy on the server goes or stays as the person says. Null when they backed out.
Future<bool?> askTurnOff(BuildContext context) => showDialog<bool>(
  context: context,
  animationStyle: Motion.dialog(context),
  builder: (context) => AlertDialog(
    content: Text(S.syncTurnOffQuestion),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(S.cancel)),
      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(S.syncKeepCopy)),
      TextButton(onPressed: () => Navigator.pop(context, true), child: Text(S.syncDeleteCopy)),
    ],
  ),
);
