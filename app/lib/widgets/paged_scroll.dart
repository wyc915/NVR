import 'package:flutter/widgets.dart';

/// Calls [onLoadMore] when the wrapped scrollable gets near its end.
class PagedScroll extends StatelessWidget {
  const PagedScroll({super.key, required this.onLoadMore, required this.child, this.threshold = 400});

  final Future<void> Function() onLoadMore;
  final Widget child;
  final double threshold;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.extentAfter < threshold) {
          onLoadMore().catchError((_) {});
        }
        return false;
      },
      child: child,
    );
  }
}
