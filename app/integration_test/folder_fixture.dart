/// The folder the emulator gate's `folders` group puts on shared storage
/// (Phase 3 W2, gate G1): `/sdcard/Documents/cf-gate`, written by
/// tool/ci/write_folder_fixture.dart and pushed with `adb push`, and read
/// back by integration_test/folders_a_test.dart and folders_b_test.dart.
/// Pure Dart, so the host-side tool can import it too.
library;

/// The folder's name, under the shared Documents folder.
const String gateFolderName = 'cf-gate';

/// A folder beside it that the app is never granted.
const String gateOutsideName = 'cf-gate-outside';

/// The picker starts inside the gate folder: Android's own storage
/// provider names it so (EXTRA_INITIAL_URI takes a document URI).
const String gateFolderStartUri =
    'content://com.android.externalstorage.documents/document/'
    'primary%3ADocuments%2F$gateFolderName';

/// The tree URI a grant for the folder beside it would have.
const String gateOutsideTreeUri =
    'content://com.android.externalstorage.documents/tree/'
    'primary%3ADocuments%2F$gateOutsideName';

/// The tree URI a grant for the shared Documents folder would have.
const String gateDocumentsTreeUri =
    'content://com.android.externalstorage.documents/tree/'
    'primary%3ADocuments';

/// The gate folder's files: path → content (UTF-8).
const Map<String, String> gateFixture = {
  'hello.txt': 'Hello from the gate\n',
  'Readme.md': '# cf-gate\n\nA folder on shared storage.\n',
  'src/app.js': "console.log('cf-gate');\n",
  'src/lib/util.js': 'export const answer = 42;\n',
  'notes/todo.md': '- list\n- read\n- write\n',
};

/// The file in the folder beside it, which must stay out of reach.
const Map<String, String> gateOutsideFixture = {
  'secret.txt': 'not for CodeForge\n',
};
