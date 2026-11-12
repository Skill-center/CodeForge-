/// The app's icons (docs/UI_DESIGN_SYSTEM.md §6, Phase 3 W4): Material
/// Symbols Rounded, from the subset bundled as
/// assets/fonts/MaterialSymbolsRounded.ttf. Each constant's comment names
/// its symbol.
///
/// The subset holds exactly the codepoints declared here:
/// tool/fonts/subset_symbols.py reads them from this file, so a new icon
/// means adding its constant and re-running the script, and
/// test/design_system/icons_test.dart fails until the font matches. The
/// subset is a static instance of the variable font: unfilled, grade 0,
/// optical size 20 (most icons here are drawn at 16 to 20 dp), weight 400.
///
/// Flutter's own widgets (the licence page, a dropdown's arrow) still draw
/// Material Icons, so pubspec.yaml keeps `uses-material-design`; the theme
/// gives app bars' back and close buttons these symbols instead. File-type
/// glyphs are in file_glyphs.dart.
library;

import 'package:flutter/widgets.dart';

abstract final class CfIcons {
  /// The family the subset is declared under in pubspec.yaml.
  static const String fontFamily = 'MaterialSymbolsRounded';

  /// `add`
  static const IconData add = IconData(0xe145, fontFamily: fontFamily);

  /// `arrow_back`, mirrored in right-to-left text.
  static const IconData arrowBack = IconData(
    0xe5c4,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `arrow_forward`, mirrored in right-to-left text.
  static const IconData arrowForward = IconData(
    0xe5c8,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `auto_awesome`
  static const IconData autoAwesome = IconData(0xe65f, fontFamily: fontFamily);

  /// `backspace`, mirrored in right-to-left text.
  static const IconData backspace = IconData(
    0xe14a,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `bolt`
  static const IconData bolt = IconData(0xea0b, fontFamily: fontFamily);

  /// `brightness_auto`
  static const IconData brightnessAuto = IconData(
    0xe1ab,
    fontFamily: fontFamily,
  );

  /// `check`
  static const IconData check = IconData(0xe668, fontFamily: fontFamily);

  /// `chevron_right`, mirrored in right-to-left text.
  static const IconData chevronRight = IconData(
    0xe5cc,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `circle`
  static const IconData circle = IconData(0xef4a, fontFamily: fontFamily);

  /// `close`
  static const IconData close = IconData(0xe5cd, fontFamily: fontFamily);

  /// `cloud_upload`
  static const IconData cloudUpload = IconData(0xe2c3, fontFamily: fontFamily);

  /// `code`
  static const IconData code = IconData(0xe86f, fontFamily: fontFamily);

  /// `commit`
  static const IconData commit = IconData(0xeaf5, fontFamily: fontFamily);

  /// `content_copy`
  static const IconData contentCopy = IconData(0xe14d, fontFamily: fontFamily);

  /// `copy_all`
  static const IconData copyAll = IconData(0xe2ec, fontFamily: fontFamily);

  /// `dark_mode`
  static const IconData darkMode = IconData(0xe51c, fontFamily: fontFamily);

  /// `delete`
  static const IconData delete = IconData(0xe92e, fontFamily: fontFamily);

  /// `description`
  static const IconData description = IconData(0xe873, fontFamily: fontFamily);

  /// `design_services`
  static const IconData designServices = IconData(
    0xf10a,
    fontFamily: fontFamily,
  );

  /// `done_all`
  static const IconData doneAll = IconData(0xe877, fontFamily: fontFamily);

  /// `drive_file_rename_outline`
  static const IconData driveFileRenameOutline = IconData(
    0xe9a2,
    fontFamily: fontFamily,
  );

  /// `error`
  static const IconData error = IconData(0xf8b6, fontFamily: fontFamily);

  /// `expand_more`
  static const IconData expandMore = IconData(0xe5cf, fontFamily: fontFamily);

  /// `extension`
  static const IconData extension = IconData(0xe87b, fontFamily: fontFamily);

  /// `find_replace`
  static const IconData findReplace = IconData(0xe881, fontFamily: fontFamily);

  /// `folder`
  static const IconData folder = IconData(0xe2c7, fontFamily: fontFamily);

  /// `folder_open`
  static const IconData folderOpen = IconData(0xe2c8, fontFamily: fontFamily);

  /// `font_download`
  static const IconData fontDownload = IconData(0xe167, fontFamily: fontFamily);

  /// `fork_right`
  static const IconData forkRight = IconData(0xebac, fontFamily: fontFamily);

  /// `format_indent_decrease`, mirrored in right-to-left text.
  static const IconData formatIndentDecrease = IconData(
    0xe23d,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `hardware`
  static const IconData hardware = IconData(0xea59, fontFamily: fontFamily);

  /// `info`
  static const IconData info = IconData(0xe88e, fontFamily: fontFamily);

  /// `inventory_2`
  static const IconData inventory2 = IconData(0xe1a1, fontFamily: fontFamily);

  /// `keyboard`
  static const IconData keyboard = IconData(0xe312, fontFamily: fontFamily);

  /// `keyboard_arrow_down`
  static const IconData keyboardArrowDown = IconData(
    0xe313,
    fontFamily: fontFamily,
  );

  /// `keyboard_arrow_left`, mirrored in right-to-left text.
  static const IconData keyboardArrowLeft = IconData(
    0xe314,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `keyboard_arrow_right`, mirrored in right-to-left text.
  static const IconData keyboardArrowRight = IconData(
    0xe315,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `keyboard_arrow_up`
  static const IconData keyboardArrowUp = IconData(
    0xe316,
    fontFamily: fontFamily,
  );

  /// `keyboard_hide`
  static const IconData keyboardHide = IconData(0xe31a, fontFamily: fontFamily);

  /// `light_mode`
  static const IconData lightMode = IconData(0xe518, fontFamily: fontFamily);

  /// `link`
  static const IconData link = IconData(0xe250, fontFamily: fontFamily);

  /// `memory`
  static const IconData memory = IconData(0xe322, fontFamily: fontFamily);

  /// `more_horiz`
  static const IconData moreHoriz = IconData(0xe5d3, fontFamily: fontFamily);

  /// `more_vert`
  static const IconData moreVert = IconData(0xe5d4, fontFamily: fontFamily);

  /// `motion_photos_off`
  static const IconData motionPhotosOff = IconData(
    0xe9c0,
    fontFamily: fontFamily,
  );

  /// `note_add`
  static const IconData noteAdd = IconData(0xe89c, fontFamily: fontFamily);

  /// `palette`
  static const IconData palette = IconData(0xe40a, fontFamily: fontFamily);

  /// `play_arrow`
  static const IconData playArrow = IconData(0xe037, fontFamily: fontFamily);

  /// `playlist_remove`
  static const IconData playlistRemove = IconData(
    0xeb80,
    fontFamily: fontFamily,
  );

  /// `receipt_long`
  static const IconData receiptLong = IconData(0xef6e, fontFamily: fontFamily);

  /// `redo`, mirrored in right-to-left text.
  static const IconData redo = IconData(
    0xe15a,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `restart_alt`
  static const IconData restartAlt = IconData(0xf053, fontFamily: fontFamily);

  /// `save`
  static const IconData save = IconData(0xe161, fontFamily: fontFamily);

  /// `search`
  static const IconData search = IconData(0xef7a, fontFamily: fontFamily);

  /// `settings`
  static const IconData settings = IconData(0xe8b8, fontFamily: fontFamily);

  /// `speed`
  static const IconData speed = IconData(0xe9e4, fontFamily: fontFamily);

  /// `terminal`
  static const IconData terminal = IconData(0xeb8e, fontFamily: fontFamily);

  /// `timer`
  static const IconData timer = IconData(0xe425, fontFamily: fontFamily);

  /// `undo`, mirrored in right-to-left text.
  static const IconData undo = IconData(
    0xe166,
    fontFamily: fontFamily,
    matchTextDirection: true,
  );

  /// `visibility`
  static const IconData visibility = IconData(0xe8f4, fontFamily: fontFamily);

  /// `visibility_off`
  static const IconData visibilityOff = IconData(
    0xe8f5,
    fontFamily: fontFamily,
  );

  /// `warning`
  static const IconData warning = IconData(0xf083, fontFamily: fontFamily);
}
