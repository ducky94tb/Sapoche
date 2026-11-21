import 'package:flutter/material.dart';

import '../../strings.dart';
import '../../theme/theme.dart';

/// The small "E" mark for songs carrying YouTube Music's explicit content badge.
class ExplicitBadge extends StatelessWidget {
  const ExplicitBadge({super.key, this.size = 15, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? context.palette.textSecondary;
    return Tooltip(
      message: S.explicit,
      excludeFromSemantics: true,
      child: Semantics(
        label: S.explicit,
        child: Icon(Icons.explicit_rounded, size: size, color: tint),
      ),
    );
  }
}
