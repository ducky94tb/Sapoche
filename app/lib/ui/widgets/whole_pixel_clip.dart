import 'package:flutter/material.dart';

/// Clips [child] to its own box with the height cut down to a whole number of device pixels. A mask over a box that ends
/// part-way through a pixel row (a tablet whose pixel ratio is not a whole number) leaves that row partly unmasked, and
/// what is under the mask shows in it as a thin line across the box; with nothing drawn in that row there is no line.
class WholePixelClip extends StatelessWidget {
  const WholePixelClip({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    clipper: _Whole(MediaQuery.devicePixelRatioOf(context)),
    child: child,
  );
}

class _Whole extends CustomClipper<Rect> {
  const _Whole(this.scale);

  final double scale;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width, (size.height * scale).floor() / scale);

  @override
  bool shouldReclip(_Whole old) => old.scale != scale;
}
