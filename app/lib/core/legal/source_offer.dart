/// The source offer and CodeForge's licence as the app shows them (Phase 5
/// W1): About → Source code, and About → CodeForge's license.
///
/// SOURCE_OFFER.md, which describes how CodeForge provides the userland's
/// corresponding source, carries the offer's paragraphs under *The offer in
/// the app*, with `{version}` for the version, and the bundled licence is a
/// copy of the repository's LICENSE: test/core/source_offer_test.dart keeps
/// both equal, so a change to one is a change to the other.
library;

/// CodeForge's repository: its source code, and every release's files.
const String repositoryUrl = 'https://github.com/Skill-center/CodeForge-';

/// Where each release's files are, its source archive among them.
const String releasesUrl = '$repositoryUrl/releases';

/// Where requests for the source go (SOURCE_OFFER.md, *Requests*).
const String issuesUrl = '$repositoryUrl/issues';

/// CodeForge's own licence, a copy of the repository's LICENSE.
const String codeForgeLicenseAsset = 'assets/licenses/CodeForge-LICENSE.txt';

/// The source archive the release workflow publishes for [version]
/// (`runtime/sources.py build --label <version>`, .github/workflows/release.yml).
String sourceArchiveName(String version) => 'codeforge-$version-sources.tar';

/// The offer's paragraphs, naming [version]'s source archive.
List<String> sourceOfferParagraphs(String version) => [
  'CodeForge is open source, under the Apache License 2.0. Its source code '
      'is at $repositoryUrl.',
  'The Linux userland inside the app is built from Termux packages. Many of '
      'them are under the GNU GPL, the GNU LGPL or another copyleft license. '
      'Open-source licenses lists every package with its license text.',
  'The complete corresponding source code of those copyleft packages is '
      'published with every release of CodeForge, next to the app, at '
      "$releasesUrl: the upstream sources, Termux's build recipes and patches "
      "at the commits that built each package, and Termux's build scripts, "
      'each file listed with its SHA-256 checksum. For this version it is '
      '${sourceArchiveName(version)}.',
  'Written offer: for at least three years after we last distribute this '
      'version of CodeForge, we will give anyone who asks a complete '
      'machine-readable copy of that source code, at no charge. To ask, open '
      'an issue at $issuesUrl.',
];
