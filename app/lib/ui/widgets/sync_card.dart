import 'package:flutter/material.dart';

import '../../strings.dart';
import '../../theme/theme.dart';
import '../scope.dart';
import '../sync_dialogs.dart';

/// Offers once, at the top of the library, to keep it safe and alike on every device. Nothing when sync is on, was sent
/// away, or there is no server to sync with.
class SyncCard extends StatelessWidget {
  const SyncCard({super.key});

  @override
  Widget build(BuildContext context) {
    final model = AppScope.of(context);
    final sync = model.sync;
    if (sync == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([sync, model.room]),
      builder: (context, _) {
        if (!sync.offerCard || !model.room.profile.configured) return const SizedBox.shrink();
        final p = context.palette;
        final text = Theme.of(context).textTheme;
        return Container(
          key: const ValueKey('sync-card'),
          margin: const EdgeInsets.fromLTRB(20, 4, 20, 10),
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
          decoration: BoxDecoration(color: p.veil, borderRadius: BorderRadius.circular(SapocheTheme.cardRadius)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.cloud_upload_outlined, color: p.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(S.syncCardTitle, style: text.titleSmall?.copyWith(color: p.text)),
                        const SizedBox(height: 2),
                        Text(S.syncCardBody, style: text.bodySmall?.copyWith(color: p.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  children: [
                    TextButton(
                      key: const ValueKey('sync-card-later'),
                      onPressed: sync.dismissCard,
                      child: Text(S.syncCardLater),
                    ),
                    TextButton(
                      key: const ValueKey('sync-card-setup'),
                      onPressed: () => startSync(context, sync),
                      child: Text(S.syncCardAction),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
