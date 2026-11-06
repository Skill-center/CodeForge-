# Phase 2 W3 phone run, 2026-11-06

**Who and what:** the owner ran the run on a **realme C51** (RMX3830: Unisoc T612, Mali-G57, 4 GB RAM, 720×1600, Android 13). The build was the profile arm64 APK `codeforge-phone-profile-arm64` from phase gate [42206498197](https://github.com/Skill-center/CodeForge-/actions/runs/42206498197). The procedure is in [PHASE_2_PHONE_CHECKLIST.md](../../PHASE_2_PHONE_CHECKLIST.md); the decision it fed is in [ADR-0004](../../../adr/0004-editor-engine.md).

| File | What it shows |
|---|---|
| `benchmark-session-1.png`, `benchmark-session-2.png` | Settings → Developer → Editor benchmark after each 6-run session. Medians per engine: first frame, typing p50/p95, 1 MiB open, 1 MiB typing p95, scroll frames over 32 ms |
| `selection-hidden-on-cursor-line.png` | The selection bug: `mmmm` on line 1 is selected (handles, copy menu) but not highlighted, while line 4's match is highlighted |
| `selection-handle-at-line-break.png` | A selection ending at the start of line 2 draws its end handle at the end of line 1. Kept for W6's selection matrix |
| `render-before-fix.png`, `render-after-fix.png` | The same document and selection rendered from the benchmark page before and after the fix (`editor/src/editor/active_line.ts`), in headless Chromium 153 at 412 px, DPR 2 |

**Frame timing** (Settings → Developer → Frame timing, after about 30 s of navigation; Phase 1 G6), as copied by the owner:

```json
{"kind":"codeforge-frame-timing","build":"profile","frames":319,"p50TotalMs":6.2,"p90TotalMs":17.3,"p99TotalMs":111.5,"maxTotalMs":384.7,"p95BuildMs":9.3,"p95RasterMs":9.4,"over16Ms":37,"over32Ms":11,"over32Pct":3.4,"budget":"G6: frames over 32 ms <= 5 %","since":"2026-11-06T12:03:51.184222Z"}
```

**The owner's notes:** "everything was good"; the cursor was good and the experience smooth, with "a little bug in selection" (the first screenshot above). The typing check's instructions were unclear, so the screen now says what to do and shows each check's result next to its buttons.

**Fix verification:** commit 58d91fa. CI 42216855073 printed `+370: All tests passed!`, and phase gate [42216855184](https://github.com/Skill-center/CodeForge-/actions/runs/42216855184) passed, with the editor-bridge test on the real page passing on attempt 1. That gate's `codeforge-phone-profile-arm64` artifact (13502173377) is the build to re-check the selection with.
