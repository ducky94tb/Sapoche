import 'package:flutter/material.dart';

/// Clips [child] to its own box with the height cut down to a whole number of device pixels, and [trim] pixels more. A
/// mask over a box that ends part-way through a pixel row (a tablet whose pixel ratio is not a whole number, or a box
/// that stands at a half pixel) leaves that row partly unmasked, and what is under the mask shows in it as a thin line
/// across the box; with nothing drawn in the last rows there is no line.
class WholePixelClip extends StatelessWidget {
  const WholePixelClip({super.key, required this.child, this.trim = 2});

  final Widget child;

  /// How many device pixels are left undrawn at the foot, over the one a part row can cost.
  final int trim;

  @override
  Widget build(BuildContext context) => ClipRect(
    clipper: _Whole(MediaQuery.devicePixelRatioOf(context), trim),
    child: child,
  );
}

class _Whole extends CustomClipper<Rect> {
  const _Whole(this.scale, this.trim);

  final double scale;
  final int trim;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    0,
    0,
    size.width,
    (((size.height * scale).floor() - trim) / scale).clamp(0.0, size.height),
  );

  @override
  bool shouldReclip(_Whole old) => old.scale != scale || old.trim != trim;
}
