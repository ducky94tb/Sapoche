import 'package:flutter/material.dart';

import 'motion.dart';

/// A full-screen page that grows out of [from], the place on screen of what was touched, and shrinks back into it. A
/// Hero cannot do this from the chat, which is a sheet and not a page. Without [from] it fades; when [Motion.still]
/// is on (Minimal effects or system "reduce motion") it opens and closes at once.
Route<T> growRoute<T>({
  required BuildContext context,
  required Rect? from,
  required WidgetBuilder builder,
}) {
  final still = Motion.still(context);
  return PageRouteBuilder<T>(
    transitionDuration: still ? Duration.zero : const Duration(milliseconds: 300),
    reverseTransitionDuration:
        still ? Duration.zero : const Duration(milliseconds: 240),
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, _, child) {
      if (still || Motion.still(context)) return child;
      final start = from;
      if (start == null) {
        return FadeTransition(opacity: animation, child: child);
      }
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      final size = MediaQuery.sizeOf(context);
      final screen = Offset.zero & size;
      // The page is drawn at its own size around the centre of the growing box, scaled to cover the box at first
      final scale0 = (start.width / size.width > start.height / size.height)
          ? start.width / size.width
          : start.height / size.height;
      return AnimatedBuilder(
        animation: curved,
        child: child,
        builder: (context, child) {
          final t = curved.value;
          final box = Rect.lerp(start, screen, t)!;
          final scale = scale0 + (1 - scale0) * t;
          return Stack(
            children: [
              Positioned.fromRect(
                rect: box,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18 * (1 - t)),
                  child: OverflowBox(
                    minWidth: size.width,
                    maxWidth: size.width,
                    minHeight: size.height,
                    maxHeight: size.height,
                    child: Transform.scale(scale: scale, child: child),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
