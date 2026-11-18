/// The oldest WebView the editor page runs in (Phase 4, decided after W5;
/// ADR-0007).
///
/// The page is built for Chrome 87 and later (`editor/tool/build.mjs`:
/// `target: ['es2020', 'chrome87']`), and an older WebView cannot even parse
/// it. An Android 8 or 9 phone that updates Android System WebView from the
/// store has up to Chrome 138, Google's last for those versions. A phone that
/// never updated keeps the WebView its image shipped: 61 to 69 on the
/// gate's API 26 to 28 images. The editor host checks before it loads the
/// page, and says what to update rather than waiting for a page that cannot
/// start.
library;

/// The page's build target, as a Chromium major version.
const int minimumWebViewMajor = 87;

final RegExp _chromeToken = RegExp(r'\bChrome/(\d+)\.');

/// The Chromium major version a WebView's user agent names
/// (`… Chrome/69.0.3497.100 Mobile Safari/537.36`), or null when it names
/// none.
int? chromeMajorVersion(String? userAgent) {
  if (userAgent == null) {
    return null;
  }
  final match = _chromeToken.firstMatch(userAgent);
  return match == null ? null : int.tryParse(match.group(1)!);
}

/// What the editor says about a WebView older than [minimumWebViewMajor].
String webViewTooOldMessage(int major) =>
    "This phone's Android System WebView is version $major, and the editor "
    'needs version $minimumWebViewMajor or later. Update Android System '
    'WebView (or Chrome) from the Play Store, then reopen CodeForge.';
