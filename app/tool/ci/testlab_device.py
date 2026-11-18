#!/usr/bin/env python3
"""Picks the Firebase Test Lab phone for CodeForge's arm64 runs (Phase 4).

Reads the JSON that `gcloud firebase test android models list --format=json`
prints (the Testing API's AndroidModel resources), and prints one device spec
for `gcloud firebase test android run --device`:

    model=<model id>,version=<API level>

The phone must be a physical phone, not a tablet or a virtual device. Its ABIs
must include arm64-v8a, Test Lab must allow the project to use it, and the
Android version must be one CodeForge supports, from minSdk 26 to targetSdk 36.
Test Lab must also have capacity for that version. Among the phones that
qualify, it prefers, in order:

  1. more capacity (Test Lab's DEVICE_CAPACITY_HIGH, then MEDIUM, then LOW),
     because a run on a scarce phone can wait in the queue for a long time;
  2. a version without a "deprecated" tag;
  3. the newer Android version;
  4. a Google phone (a Pixel), the closest to stock Android;
  5. the model id, so the same list always gives the same choice.

With --runtime (Phase 4 W5: the runtime's arm64 gates, G3 and G6), the phone
must run Android 14 or later (API 34+, PHASE_4_PLAN W5), and among the phones
with high or medium capacity a mid-range one comes first: G3's budget for the
first install is 60 s on a mid-range phone, which a flagship would flatter.
Mid-range is the maker's own line, by name: Pixel a (Pixel 8a), Galaxy A,
moto g, Redmi Note, OnePlus Nord. A scarce phone still comes last.

Usage:
  testlab_device.py <models.json> [--list N] [--runtime]
                                  prints the spec on stdout; on stderr, how
                                  many qualified and the N best (default 5)
  testlab_device.py --self-test   shows the choice on samples

Exit codes: 0 a phone was chosen, 1 none qualifies, 2 usage.
"""

import json
import re
import sys

MIN_SDK = 26        # app/android/app/build.gradle.kts (ADR-0007)
TARGET_SDK = 36
ABI = "arm64-v8a"
CAPACITY = {"DEVICE_CAPACITY_HIGH": 3, "DEVICE_CAPACITY_MEDIUM": 2,
            "DEVICE_CAPACITY_LOW": 1}
UNKNOWN_CAPACITY = 0.5      # no perVersionInfo for that version
NO_CAPACITY = "DEVICE_CAPACITY_NONE"
RUNTIME_MIN_SDK = 34    # Android 14 (PHASE_4_PLAN W5, the arm64 leg)
MID_RANGE = re.compile(r"\bpixel \d+a\b|\bgalaxy a\d+|\bmoto g\b|\bredmi note\b|\bnord\b",
                       re.IGNORECASE)


def mid_range(model):
    return bool(MID_RANGE.search("%s %s" % (model.get("manufacturer", ""), model.get("name", ""))))


def api_level(version_id):
    match = re.match(r"^(\d+)", str(version_id))
    return int(match.group(1)) if match else None


def deprecated_versions(tags):
    """Versions a model's tags deprecate; None means the whole model."""
    versions = set()
    for tag in tags or []:
        name, _, value = str(tag).partition("=")
        if name.strip().lower() != "deprecated":
            continue
        if not value:
            return None
        versions.update(item.strip() for item in value.split(",") if item.strip())
    return versions


def candidates(models, runtime=False):
    """(sort key, spec, description) for every qualifying model and version."""
    found = []
    lowest = RUNTIME_MIN_SDK if runtime else MIN_SDK
    for model in models:
        if model.get("form") != "PHYSICAL" or model.get("formFactor") != "PHONE":
            continue
        if ABI not in (model.get("supportedAbis") or []):
            continue
        if model.get("accessDeniedReasons"):
            continue
        deprecated = deprecated_versions(model.get("tags"))
        info = {str(item.get("versionId")): item for item in model.get("perVersionInfo") or []}
        for version in model.get("supportedVersionIds") or []:
            version = str(version)
            level = api_level(version)
            if level is None or not lowest <= level <= TARGET_SDK:
                continue
            per_version = info.get(version)
            if per_version is None:
                capacity_name, capacity = "unknown", UNKNOWN_CAPACITY
            else:
                capacity_name = per_version.get("deviceCapacity", "DEVICE_CAPACITY_UNSPECIFIED")
                if capacity_name == NO_CAPACITY:
                    continue
                capacity = CAPACITY.get(capacity_name, UNKNOWN_CAPACITY)
            is_deprecated = deprecated is None or version in deprecated
            google = str(model.get("manufacturer", "")).lower() == "google"
            middle = mid_range(model)
            key = (-capacity, is_deprecated, -level, not google, str(model.get("id")))
            if runtime:
                key = (capacity < CAPACITY["DEVICE_CAPACITY_MEDIUM"], not middle) + key
            spec = "model=%s,version=%s" % (model.get("id"), version)
            description = "%s %s (%s), API %s, capacity %s%s%s" % (
                model.get("manufacturer", "?"), model.get("name", "?"), model.get("id"),
                version, capacity_name.replace("DEVICE_CAPACITY_", "").lower(),
                ", deprecated" if is_deprecated else "", ", mid-range" if middle else "")
            found.append((key, spec, description))
    found.sort(key=lambda item: item[0])
    return found


def choose(models, listed=5, out=sys.stderr, runtime=False):
    found = candidates(models, runtime)
    physical = sum(1 for m in models if m.get("form") == "PHYSICAL")
    print("Test Lab lists %d models, %d of them physical; %d phone and version pairs qualify "
          "(physical phone, %s, API %d to %d, capacity left, access allowed%s)"
          % (len(models), physical, len(found), ABI, RUNTIME_MIN_SDK if runtime else MIN_SDK,
             TARGET_SDK, "; a mid-range phone first, unless scarce" if runtime else ""),
          file=out)
    for index, (_, spec, description) in enumerate(found[:listed]):
        print("  %s %s  %s" % ("->" if index == 0 else "  ", spec, description), file=out)
    return found[0][1] if found else None


def self_test():
    def model(id_, manufacturer="Google", form="PHYSICAL", form_factor="PHONE",
              abis=("arm64-v8a",), versions=(), tags=(), denied=None, name=None):
        entry = {"id": id_, "name": name or id_.title(), "manufacturer": manufacturer, "form": form,
                 "formFactor": form_factor, "supportedAbis": list(abis), "tags": list(tags),
                 "supportedVersionIds": [v for v, _ in versions],
                 "perVersionInfo": [{"versionId": v, "deviceCapacity": c}
                                    for v, c in versions if c is not None]}
        if denied:
            entry["accessDeniedReasons"] = [denied]
        return entry

    high, medium, low = "DEVICE_CAPACITY_HIGH", "DEVICE_CAPACITY_MEDIUM", "DEVICE_CAPACITY_LOW"
    cases = [
        ("the most capacity wins over a newer version",
         [model("oriole", versions=[("33", high)]), model("tokay", versions=[("35", medium)])],
         "model=oriole,version=33"),
        ("then the newer version",
         [model("oriole", versions=[("32", high), ("33", high)])],
         "model=oriole,version=33"),
        ("a deprecated version loses",
         [model("oriole", versions=[("33", high)], tags=["deprecated=33"]),
          model("redfin", versions=[("30", high)])],
         "model=redfin,version=30"),
        ("then a Google phone",
         [model("a51", manufacturer="Samsung", versions=[("33", high)]),
          model("oriole", versions=[("33", high)])],
         "model=oriole,version=33"),
        ("virtual devices, tablets, x86 phones and denied phones never qualify",
         [model("MediumPhone.arm", form="VIRTUAL", versions=[("35", high)]),
          model("tangorpro", form_factor="TABLET", versions=[("35", high)]),
          model("x86phone", abis=("x86_64",), versions=[("35", high)]),
          model("locked", versions=[("35", high)], denied="EULA_NOT_ACCEPTED"),
          model("felix", versions=[("34", low)])],
         "model=felix,version=34"),
        ("versions outside API 26 to 36 and without capacity never qualify",
         [model("future", versions=[("37", high)]), model("old", versions=[("25", high)]),
          model("busy", versions=[("35", "DEVICE_CAPACITY_NONE")]),
          model("panther", versions=[("33", None)])],
         "model=panther,version=33"),
        ("nothing qualifies", [model("old", versions=[("24", high)])], None),
    ]
    flagship = model("komodo", versions=[("35", high)], name="Pixel 9 Pro XL")
    cases += [
        ("runtime: Android 14 or later only",
         [model("oriole", versions=[("33", high)]), model("felix", versions=[("34", low)])],
         "model=felix,version=34", True),
        ("runtime: a mid-range phone before a flagship with as much capacity",
         [flagship, model("akita", versions=[("34", high)], name="Pixel 8a"),
          model("a35x", manufacturer="Samsung", versions=[("34", medium)], name="Galaxy A35 5G")],
         "model=akita,version=34", True),
        ("runtime: medium capacity is enough for a mid-range phone",
         [flagship, model("a35x", manufacturer="Samsung", versions=[("34", medium)],
                          name="Galaxy A35 5G")],
         "model=a35x,version=34", True),
        ("runtime: but a scarce one comes after any with capacity",
         [flagship, model("tegu", versions=[("36", low)], name="Pixel 9a")],
         "model=komodo,version=35", True),
        ("without --runtime, capacity and version decide as before",
         [flagship, model("akita", versions=[("34", high)], name="Pixel 8a")],
         "model=komodo,version=35", False),
    ]
    failed = 0
    for case in cases:
        name, models, expected = case[:3]
        runtime = case[3] if len(case) > 3 else False
        sink = open("/dev/null", "w")
        try:
            got = choose(models, out=sink, runtime=runtime)
        finally:
            sink.close()
        status = "ok" if got == expected else "FAILED"
        failed += got != expected
        print("self-test %-6s %s: %s" % (status, name, got))
    print("self-test: %s" % ("all cases pass" if not failed else "%d case(s) failed" % failed))
    return 1 if failed else 0


def main(argv):
    if argv[1:] == ["--self-test"]:
        return self_test()
    args = list(argv[1:])
    runtime = "--runtime" in args
    if runtime:
        args.remove("--runtime")
    if len(args) not in (1, 3) or (len(args) == 3 and args[1] != "--list"):
        print(__doc__, file=sys.stderr)
        return 2
    listed = int(args[2]) if len(args) == 3 else 5
    with open(args[0], encoding="utf-8") as handle:
        models = json.load(handle)
    spec = choose(models, listed, runtime=runtime)
    if spec is None:
        print("no Test Lab phone qualifies", file=sys.stderr)
        return 1
    print(spec)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
