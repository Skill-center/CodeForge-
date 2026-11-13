# runtime/: the sealed runtime's supply chain

The scripts that turn pinned Termux packages into the sealed payload the app ships, and the pins themselves (Phase 4 W2). Vendored from t1 byte for byte, plus CodeForge's own pinning, notices and provenance tools; native/PROVENANCE.md says which file is which. W3 wires them into the Gradle build, the way t1 does: generated assets, verified while written, never committed.

## The pieces

| File | Origin | Does |
|---|---|---|
| `pins.json` | CodeForge | Pins every input: the bootstrap for each ABI (URL, SHA-256), the core set asked for, and every resolved package (version, file, size, SHA-256) in install order |
| `pins.py` | CodeForge | `check` the pins offline · `fetch` exactly the pinned packages (fails closed) · `bootstrap` · `resolve` (re-pin) |
| `fetch-core-debs.py` | t1 | Termux's index, the dependency resolver, downloads. `pins.py` imports it |
| `build-sealed-payload.py` | t1 | Splits the bootstrap and the `.deb`s into the payload: `userland-<abi>.zip`, the manifests, `jniLibs/<abi>/lib*.so` |
| `check-sealed-manifest.sh` | t1 | Checks that a payload tree is sealed |
| `check-bundle-size.py`, `check-page-alignment.py` | t1 | Play's 200 MB base-module limit, 16 KB page alignment |
| `notices.py` | CodeForge | Drafts THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md from the pinned packages' licence files |
| `provenance.py` | CodeForge | Checks native/PROVENANCE.md against the vendored files |
| `tests/` | both | t1's two script tests; CodeForge's pins, notices and provenance tests; the live fail-closed check |

## Commands

```bash
python3 runtime/pins.py check                     # offline: shape, hashes, dependencies met
python3 runtime/pins.py bootstrap --arch x86_64 --cache runtime/generated/cache --out runtime/generated/bootstrap
python3 runtime/pins.py fetch --arch x86_64 --cache runtime/generated/cache --out runtime/generated/debs/x86_64
python3 runtime/build-sealed-payload.py --bootstrap runtime/generated/bootstrap/bootstrap-x86_64.zip \
    --abi x86_64 --deb-dir runtime/generated/debs/x86_64 --out runtime/generated/payload
python3 runtime/notices.py --cache runtime/generated/cache [--check]
python3 runtime/provenance.py check
for t in runtime/tests/test-*.py; do python3 "$t" || echo "FAILED: $t"; done
```

`runtime/generated/` is ignored by Git. Architectures use Termux's names (`aarch64`, `x86_64`); the payload builder takes the Android ABI (`arm64-v8a`, `x86_64`).

## How pinning works

- **Fetching never resolves.** `fetch` downloads the files the pins name and nothing else, and checks each against its pinned SHA-256. It reuses a verified file from the cache, and gives the payload builder a directory holding only the pinned files, with t1's `packages.json`.
- **Failing closed.** Termux keeps only the latest version of each package. When a pinned file is gone, `fetch` exits 1, names every missing package with what the index lists now, and hands nothing over. Changed bytes or a different bootstrap fail the same way. Nothing falls back to "whatever is current".
- **CI keeps the pinned files.** CI caches `runtime/generated/cache` under the hash of `pins.json`, so a pinned version that Termux has dropped still builds from the cache. GitHub drops a cache that goes unused for 7 days; a build after that has to download again, and fails closed if the files are gone.
- **Re-pinning is a deliberate commit.** A commit whose message contains `[repin]` makes CI run `pins.py resolve` against the live repository, with t1's resolver and the pinned bootstrap. CI then fetches and checks the result, regenerates the notices, and commits `pins.json` back. Review the new versions as you would a dependency upgrade. On a machine that can reach the Termux repository, `python3 runtime/pins.py resolve --cache runtime/generated/cache` does the same.
- **A mirror waits.** Hosting the pinned packages (a GitHub release, for example) would redistribute GPL binaries, so it is considered together with the source offer (SOURCE_OFFER.md, W7).
