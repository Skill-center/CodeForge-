/// Spacing, radius, elevation and motion tokens (docs/UI_DESIGN_SYSTEM.md §3).
library;

import 'package:flutter/animation.dart';

/// 4 dp grid. Touch targets are ≥ 48 dp regardless of visual size.
abstract final class CfSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const double minTouchTarget = 48;
  static const double statusStripHeight = 24;
  static const double activityBarHeight = 56;
  static const double navRailWidth = 64;

  /// Tabs and their close buttons are touch targets, so the strip is 48 (G7).
  static const double tabStripHeight = 48;
  static const double symbolToolbarHeight = 44;
}

/// Radii — never above 14; no pill cards.
abstract final class CfRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
}

/// Motion — durations and curves. `CfMotionScope` disables non-essential
/// animation when the user enables reduced motion.
abstract final class CfMotion {
  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve entrance = Curves.easeOutQuart;
  static const Curve exit = Curves.easeInCubic;
}
