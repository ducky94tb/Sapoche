import 'package:flutter/material.dart';

import '../../theme/palette.dart';
import '../../theme/theme.dart';
import '../cover_glow.dart';
import 'motion.dart';

/// The ground of the player in the style of cards: one colour, that of the top of the picture the classic player and
/// the full cover are drawn on ([CoverGlow.ground]), fading down to near black (to a pale tint of itself in the light
/// theme), standing still. It changes from song to song by fading.
class FlatBackdrop extends StatefulWidget {
  const FlatBackdrop({super.key, required this.coverUrl});

  final String? coverUrl;

  /// What the colour fades to in the dark theme.
  static const floor = Color(0xFF121212);

  @override
  State<FlatBackdrop> createState() => _FlatBackdropState();
}

class _FlatBackdropState extends State<FlatBackdrop> {
  Color? _tone;
  bool? _light;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final light = context.palette.brightness == Brightness.light;
    if (light == _light) return;
    _light = light;
    _load();
  }

  @override
  void didUpdateWidget(FlatBackdrop old) {
    super.didUpdateWidget(old);
    if (widget.coverUrl != old.coverUrl) _load();
  }

  Future<void> _load() async {
    final url = widget.coverUrl;
    final light = _light!;
    final tone = url == null ? null : await CoverGlow.ground(url, light: light, vivid: light);
    if (!mounted || widget.coverUrl != url || _light != light) return;
    setState(() => _tone = tone);
  }

  @override
  Widget build(BuildContext context) {
    final light = context.palette.brightness == Brightness.light;
    final floor = light ? Palette.light.base : FlatBackdrop.floor;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: _tone ?? floor),
      duration: Motion.of(context, 600),
      builder: (context, tone, _) {
        final top = tone ?? floor;
        // In the light theme it does not fade to plain white: the lower part keeps a good deal of the colour
        final bottom = light ? Color.lerp(top, floor, 0.55)! : floor;
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [top, bottom],
              stops: [0, light ? 0.9 : 0.7],
            ),
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}
