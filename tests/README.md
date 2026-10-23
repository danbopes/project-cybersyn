# Tests

Three layers. The first two gate every commit (both green); the third is how GUI changes get looked at.

| Layer | Where | Needs | Wall time |
|---|---|---|---|
| Host unit tests | `tests/unit/` | `lua5.2` only | about 0.05 s |
| In-game characterization suite | `tests/lab/` | Factorio 2.0 headless, `lab.sh` | about 14 s |
| Screenshots | `~/factorio/manager-facelift/shots.sh` | the virtual display on `:2`, a running lab | about 30 s on layout-dev |

## 1. Host unit tests (`tests/unit`)

```
tests/unit/run.sh                 # from anywhere; VERBOSE=1 for tracebacks
CYBERSYN_ROOT=<cybersyn dir> tests/unit/run.sh   # same tests against another copy of the mod
```

Plain Lua 5.2 against the mod's real modules (`constants`, `lib`, `factorio-api`, `central-planning`, `diag`, `stats`, `gui/util`, `gui/collector`, the stations and trains tab queries). `harness.lua` stubs the engine (`game`, `prototypes`, `storage`, a fake `LuaGuiElement`, flib's `format`, `gui.add`, `train`). Every test runs in a fresh harness state. Prints `FAIL <file>: <test>: <message>` per failure and a final `PASS n FAIL m`; exits 1 on any failure. New tests go in `tests/unit/<name>_test.lua`.

## 2. In-game suite (`tests/lab`)

```
tests/lab/run.sh <scratch> <rcon port> [save.zip] [--record]
```

Boots `~/factorio/manager-facelift/saves/layout-dev.zip` headless (2 s), records a golden dispatch trace with a fixed stimulus, runs `aitest` and drives every manager tab, sort, filter, period and pager through the `cybersyn-manager-dev` remote interface, builds one planner scenario per reason code (`40_reason_codes_test.lua`), then compares against `tests/baseline/`. One `PASS`/`FAIL`/`INFO` line per check (`SKIP` for a check whose subject does not exist yet, such as the reason checks before the diagnostics core lands), `SKIP k` and `PASS n FAIL m` at the end, non-zero exit on failure. The lab is always stopped. Details, the suite protocol and helpers are in `tests/lab/README.md`. New suites go in `tests/lab/NN_name_test.lua` (only `*_test.lua` files run).

## 3. Screenshots

```
lab.sh <scratch> start <mod root> <port> ~/factorio/manager-facelift/saves/layout-dev.zip
SHOT_PREFIX=layout- shots.sh <scratch> <port> <outdir> [scale] [WxH] [tabs...]
lab.sh <scratch> stop
```

One PNG per tab at the given UI scale and resolution; settle and gap times grow automatically on saves with more than 100 stations (pY). Look at every PNG. The round-3 "before" gallery is `~/factorio/manager-facelift/shots/round3/before/`. See `~/factorio/manager-facelift/README.md`.

## Baselines

`tests/baseline/`:
- `dispatch-trace.json`: the golden train trace (and per-station trace) over ticks 22200..33000.
- `summary.json`: every tab's rows, filters, sorts, station statuses and the Overview model at the window's last tick.
- `save.sha1`: the save they were recorded on. A different save fails the run; re-saving `layout-dev.zip` means re-recording.

Regenerate only when a PLAN3 phase deliberately changes semantics (planner decisions per §4.8c, or what a summary field, dump or Overview tile means):

```
tests/lab/run.sh <scratch> <port> --record     # rewrites tests/baseline/
tests/lab/run.sh <scratch> <port>              # must then be green against the new baseline
```

The commit that rewrites a baseline must say which change caused it and why. A refactor that only moves code must pass against the existing baseline unchanged; a divergence there is a bug, not a reason to re-record.
