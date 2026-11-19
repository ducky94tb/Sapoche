import 'package:flutter/material.dart';

import '../../theme/theme.dart';

/// A short note in the middle of a panel of the full player, with a way to try again when there is one.
class PlayerMessage extends StatelessWidget {
  const PlayerMessage({
    super.key,
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // A panel that is short (the small player of a phone on its side) has less room round the note
    final short = MediaQuery.sizeOf(context).height < 480;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(short ? 8 : 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: short ? 28 : 36, color: p.textTertiary),
            SizedBox(height: short ? 6 : 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: p.textSecondary),
            ),
            if (action != null) ...[
              const SizedBox(height: 6),
              TextButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}
