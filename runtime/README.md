# runtime/: the sealed runtime's supply chain

The scripts that turn pinned Termux packages into the sealed payload the app ships, and the pins themselves (Phase 4 W2). Vendored from t1 byte for byte, plus CodeForge's own pinning, notices and provenance tools; native/PROVENANCE.md says which file is which. Since W3 the Gradle build runs them the way t1 does: for each payload ABI, `native/runtime-core`'s tasks fetch the pinned files, build the payload and put it into the APK as generated assets and JNI libraries, never committed. The app verifies every file while it writes it.

## The pieces

| File | Origin | Does |
|---|---|---|
| `pins.json` | CodeForge | Pins every input: the bootstrap for each ABI (URL, SHA-256), the core set asked for, and every resolved package (version, file, size, SHA-256) in install order |
| `pins.py` | CodeForge | `check` the pins offline · `fetch` exactly the pinned packages (fails closed) · `bootstrap` · `resolve` (re-pin) · `info`, the payload's description for the app (`runtime-info-<abi>.json`: Termux's bootstrap, the package count, the pin date and the core packages' versions) |
| `fetch-core-debs.py` | t1 | Termux's index, the dependency resolver, downloads. `pins.py` imports it |
| `build-sealed-payload.py` | t1 | Splits the bootstrap and the `.deb`s into the payload: `userland-<abi>.zip`, the manifests, `jniLibs/<abi>/lib*.so` |
| `check-sealed-manifest.sh` | t1 | Checks that a payload tree is sealed |
| `check-bundle-size.py`, `check-page-alignment.py` | t1 | Play's 200 MB base-module limit, 16 KB page alignment |
| `notices.py` | CodeForge | Drafts THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md from the pinned packages' licence files, and (Phase 5 W1) writes their texts for the app's licence page, `app/assets/licenses/userland.txt`: each distinct text once, after the packages that carry it, a link followed to its text, and a text missing from the payload failing the run |
| `sources.py` | CodeForge | (Phase 5 W1) Builds the source archive SOURCE_OFFER.md promises: for each copyleft package version in its table, the termux-packages commit whose recipe gives that version, that recipe and Termux's build system at that commit, and the upstream files from the recipe's URLs, each verified against the recipe's SHA-256. Fails closed, naming the package; the same inputs give the same bytes |
| `provenance.py` | CodeForge | `check`s native/PROVENANCE.md against the vendored files · `copy` re-vendors them from a t1 checkout with their recorded change · `record` writes the hashes |
| `language_servers.py`, `language-servers/` | CodeForge | (Phase 6 W2, ADR-0015) The language servers: `package.json` pins their npm packages and says which make up each server, npm's lockfile pins every package with its SHA-512, and `bundled.json` lists the packages bundled inside their JavaScript (from the source maps), for the notices. `check` the pins offline · `fetch` the tarballs, verified · `build` each server's archive and manifest (refusing native code), which Gradle puts in the APK beside the userland · `notices` · `lock` (re-pin, with npm) |
| `tests/` | both | t1's two script tests; CodeForge's pins, notices, provenance, launcher and sources tests; the live fail-closed check |

## Commands

```bash
python3 runtime/pins.py check                     # offline: shape, hashes, dependencies met
python3 runtime/pins.py bootstrap --arch x86_64 --cache runtime/generated/cache --out runtime/generated/bootstrap
python3 runtime/pins.py fetch --arch x86_64 --cache runtime/generated/cache --out runtime/generated/debs/x86_64
python3 runtime/build-sealed-payload.py --bootstrap runtime/generated/bootstrap/bootstrap-x86_64.zip \
    --abi x86_64 --deb-dir runtime/generated/debs/x86_64 --out runtime/generated/payload
python3 runtime/notices.py --cache runtime/generated/cache [--check]
git clone --filter=blob:none --no-checkout https://github.com/termux/termux-packages.git /tmp/termux-packages
python3 runtime/sources.py plan --termux /tmp/termux-packages [--json plan.json]   # commits and URLs, no downloads
python3 runtime/sources.py build --termux /tmp/termux-packages --cache runtime/generated/sources-cache \
    --out codeforge-0.1.0-sources.tar --label 0.1.0
python3 runtime/pins.py info --arch x86_64 --out runtime/generated/payload/assets/runtime-info-x86_64.json
python3 runtime/provenance.py check
python3 runtime/provenance.py copy --t1 /path/to/t1   # at PROVENANCE's commit; then record
python3 runtime/language_servers.py check        # offline: the language servers' pins and rules
python3 runtime/language_servers.py build --out runtime/generated/lsp-build   # fetches into runtime/generated/lsp-cache
python3 runtime/language_servers.py notices [--check]
python3 runtime/language_servers.py lock         # re-pin after editing language-servers/package.json (needs npm)
for t in runtime/tests/test-*.py; do python3 "$t" || echo "FAILED: $t"; done
```

`runtime/generated/` is ignored by Git. Architectures use Termux's names (`aarch64`, `x86_64`); the payload builder takes the Android ABI (`arm64-v8a`, `x86_64`).

## The source archive (Phase 5 W1)

`sources.py` reads termux-packages through Git, so a blobless clone is enough (about 65 MB; it fetches the blobs it reads, in batches, and writes a commit-graph with changed-path filters the first time, which takes a plan from minutes to about 9 s). For each row of SOURCE_OFFER.md's copyleft table:

- **The commit.** Among the commits that touched the package's folder, the newest one at or before the point the package was built, whose recipe gives the pinned version (Termux's rule: `TERMUX_PKG_VERSION`, then `-TERMUX_PKG_REVISION` when the revision isn't 0 or the version holds a `-`). That point is the pins' date for a pinned package, and the bootstrap's tag for a package from the bootstrap. A subpackage is found through its parent's folder.
- **The recipe**, read without running it: `build.sh` is sourced by bash with only text filters on `PATH` (sed under `--sandbox`), and its build steps run with `termux_download` recorded, so a source downloaded in a step is found. Downloads that only build tools for the build machine are left out, each with its reason (`STEP_DOWNLOADS`), and `MANIFEST.json` says so; a download in a step nobody reviewed fails the build.
- **The files.** Each URL is downloaded (curl, three attempts), verified against the recipe's SHA-256, and kept in the cache under that hash; a Git source is a depth-1 clone at its tag, with submodules, made into a deterministic tar. A mismatch, a missing file or a recipe that gives no source fails the build.
- **Mirrors.** When a file's host fails, the same path is tried on the hosts that serve the same files (`MIRRORS`: GNU's tree, kernel.org's, Savannah's, GnuPG's, nano's versioned folder for its `latest/`, which holds only the newest release, Thomas Dickey's mirror and SourceForge's download host, and for the two files fossies.org refuses with HTTP 401, their upstreams; 53 of the 68 upstream archives have one). A file still counts only with the recipe's SHA-256, and the manifest names the recipe's URL, so the archive is the same bytes whichever host answered; the log says where a file came from (`  mirror:` lines). A host that failed goes last for the rest of the run. The first dry run needed this: mirrors.kernel.org, which 36 of the 69 upstream files name, never answered CI's runner (CI 44389009942).

The archive, `codeforge-<label>-sources/`: `MANIFEST.json` (per package: its licence, the binaries it ships in with their SHA-256, and per recipe the commit, the folder and every source with its URL and SHA-256), a README, `termux-packages/<commit>/` (Termux's build system and the recipe folders) and `upstream/<recipe>-<version>/`. It is written in PAX format with fixed times and owners, sorted, with repeated content as hard links, so it is reproducible. CI builds it in every release run (`.github/workflows/release.yml`).

## How pinning works

- **Fetching never resolves.** `fetch` downloads the files the pins name and nothing else, and checks each against its pinned SHA-256. It reuses a verified file from the cache, and gives the payload builder a directory holding only the pinned files, with t1's `packages.json`.
- **The payload is consistent.** The payload is the bootstrap, with the pinned packages replacing its copies. A Termux subpackage depends on its parent's exact version: the bootstrap's `curl` 8.18.0-1 needs `libcurl (= 8.18.0-1)`. So when a replacement leaves a bootstrap package's dependency unmet, `resolve` adds that package to the request and resolves again, until every dependency in the payload is met. The packages it added are listed under `consistency` in `pins.json`. `check` verifies the whole payload, the bootstrap's packages included, and a package that cannot follow fails the resolve.
- **Failing closed.** Termux keeps only the latest version of each package. When a pinned file is gone, `fetch` exits 1, names every missing package with what the index lists now, and hands nothing over. Changed bytes or a different bootstrap fail the same way. Nothing falls back to "whatever is current".
- **CI keeps the pinned files.** CI caches `runtime/generated/cache` under the hash of `pins.json`, so a pinned version that Termux has dropped still builds from the cache. GitHub drops a cache that goes unused for 7 days; a build after that has to download again, and fails closed if the files are gone.
- **Re-pinning is a deliberate commit.** A commit whose message contains `[repin]` makes CI run `pins.py resolve` against the live repository, with t1's resolver and the pinned bootstrap. CI then fetches and checks the result, regenerates the notices, and commits `pins.json` back. Review the new versions as you would a dependency upgrade. On a machine that can reach the Termux repository, `python3 runtime/pins.py resolve --cache runtime/generated/cache` does the same.
- **A mirror waits.** Hosting the pinned packages (a GitHub release, for example) would redistribute GPL binaries, so it is considered together with the source offer (SOURCE_OFFER.md, W7).
