part of 'package:beastcode/main.dart';

class _EqualizerBars extends StatefulWidget {
  final double size;
  final Color color;
  const _EqualizerBars({required this.size, required this.color});
  @override
  State<_EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<_EqualizerBars>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _anims;

  static const _barCount = 4;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(_barCount, (i) {
      final ctrl = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 300 + i * 80),
      );
      ctrl.repeat(reverse: true);
      return ctrl;
    });
    _anims = _controllers
        .map((c) => Tween<double>(begin: 0.2, end: 1.0)
            .animate(CurvedAnimation(parent: c, curve: Curves.easeInOut)))
        .toList();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size * 1.2,
      height: widget.size,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(_barCount, (i) {
          return AnimatedBuilder(
            animation: _anims[i],
            builder: (_, __) => Container(
              width: widget.size * 0.18,
              height: widget.size * _anims[i].value,
              decoration: BoxDecoration(
                color: widget.color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
