import 'package:flutter/material.dart';

Duration ledgerMotionDuration(BuildContext context, {int milliseconds = 260}) {
  final media = MediaQuery.maybeOf(context);
  return media?.disableAnimations == true || media?.accessibleNavigation == true
      ? Duration.zero
      : Duration(milliseconds: milliseconds);
}

/// Only tab changes animate. The child stays mounted to preserve page state.
class LedgerTabTransition extends StatefulWidget {
  const LedgerTabTransition({super.key, required this.index, required this.child});
  final int index;
  final Widget child;
  @override
  State<LedgerTabTransition> createState() => _LedgerTabTransitionState();
}

class _LedgerTabTransitionState extends State<LedgerTabTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  late final Animation<double> _curve = _controller.drive(
    CurveTween(curve: Curves.easeOutCubic),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = ledgerMotionDuration(context, milliseconds: 240);
    if (_controller.duration == Duration.zero) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }
  @override
  void didUpdateWidget(LedgerTabTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      if (_controller.duration == Duration.zero) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _curve,
    child: SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, .015), end: Offset.zero).animate(_curve),
      child: widget.child,
    ),
  );
}
