/// Responsive breakpoints (docs/UI_DESIGN_SYSTEM.md §4).
///
/// One resolver drives every adaptive decision in the workbench so layouts
/// cannot disagree about what "tablet" means.
library;

enum CfFormFactor { compact, medium, expanded }

/// compact < 600 dp · medium 600–840 dp · expanded > 840 dp.
CfFormFactor formFactorFor(double width) {
  if (width < 600) {
    return CfFormFactor.compact;
  }
  if (width <= 840) {
    return CfFormFactor.medium;
  }
  return CfFormFactor.expanded;
}

/// Landscape is decided from the available surface, not device orientation,
/// so split-screen and freeform windows behave correctly.
bool isLandscapeSurface(double width, double height) => width > height;
