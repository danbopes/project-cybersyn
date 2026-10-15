# In-game characterization suite

Proves the manager GUI and the Cybersyn planner behave the same before and after a refactor. It boots the fast dev save headless, records a golden dispatch trace, drives the manager through its dev remote interface and compares against `tests/baseline/`.

```
tests/lab/run.sh <scratch> <rcon port> [save.zip] [--record]
```

- `<scratch>`: the lab's scratch dir (one lab per scratch dir and port; the game port is rcon + 7000).
- `save.zip`: defaults to `~/factorio_20/manager-facelift/saves/layout-dev.zip`. The suite's expectations (30 stations, 6 trains, the `cyb-bench` stimulus) belong to that save; other saves boot but will fail those checks.
- `--record`: rewrite `tests/baseline/` from this run (see below).
- Prints one `PASS`/`FAIL`/`INFO` line per check, then `PASS n FAIL m`; exits non-zero on any failure. A test file that prints no `DONE` (never calls `lab.suite`, or returns early) or runs no checks fails. A first RCON login that fails is retried once with a fresh start. The full RCON transcript is in `<scratch>/lab-run.log`, the result lines in `<scratch>/lab-results.txt`.
- Environment overrides: `MOD=<mod root>` (default: the `cybersyn/` next to `tests/`), `LAB=<lab.sh>`, `TRACE_LENGTH` (ticks, default 10800), `TRACE_SPEED` (default 20). Changing `TRACE_LENGTH` makes the trace incomparable with the baseline.

## What runs, in order

1. `lab.sh start` with the worktree's mod root, then `lib.lua` (helpers in the level-scope global `lab`).
2. `dispatch_trace.lua`, the golden trace recorder, before anything can touch the world. The runner polls until the window is done (about 10 s wall).
3. Every `tests/lab/*_test.lua` in sorted order:
   - `10_smoke_test.lua`: `remote.call("aitest", "run_all")`, one check per aitest test, `check_dispatch` all true. aitest builds a station on nauvis; the suite destroys the entities it added (with `raise_destroy`) so later suites see the save's 30 stations again.
   - `20_manager_test.lua`: freezes the planner (`cybersyn-enable-planner` off, restored at the end) so no new dispatch reshuffles rows between dumps; every tab renders (`update(pi, 5)`, timings as `INFO`); dump order identical 2 s apart; every sort column ascending and descending is ordered by the dumped key values; inventory captions match the aggregate (`stale == 0`) and every aggregated item is shown; filters (query, item, network, mask, surface) never add a row, and the network/mask filters keep exactly the stations an oracle computed from Cybersyn's own `stations` table (and do narrow); each status chip shows exactly the stations of that status in the unfiltered order, with its count; striping; paging bounds and clamping; `set_period` 10/60/1440 with every Overview list's rendered rows matching its model rows; hover on a station row holds, leave releases; pause freezes `last_update_tick`; heap growth over a full `bench_pass` under 10,000 KB; summary invariants.
   - `30_dispatch_trace_test.lua`: in-game sanity of the recorded trace (registered in time, dispatches and completed deliveries happened, operator acted).
   - `40_foundation_test.lua` (PLAN3 phase 1): opening with no snapshot collects nothing synchronously, the status caption reads "Collecting… n %" until a boosted pass completes within 3 updates; Saturated is one number (Overview tile == Stations chip == chip rows, with one station at its limit and one disabled with a delivery); a train leaving the fleet mid-pass leaves the Trains tab and the Fleet tile together (planner off, the train's storage entity cleared and restored); `parse_name` on a rich-text name and on every station of the save.
4. Render budgets: `run.sh` parses the `update <tab>` timings and fails Overview at 3 ms or more and any other tab at 5 ms or more (about 6x to 400x what HEAD measures on layout-dev, so only a gross regression trips them; the real budgets are on pY, PLAN3 §2.11).
5. `compare.py` compares `script-output/lab/dispatch-trace.json` and `summary.json` with `tests/baseline/` and prints the first divergence.

## The suite protocol

Each RCON command is its own chunk, so state lives in the global `lab`. A test file calls `lab.suite(name, steps)`. A step that needs game time calls `lab.wait(ticks[, speed])` and returns; the file prints `WAIT <tick>` and the RCON call ends, so the server keeps ticking (at `game.speed` 20 during waits). The runner then calls `lab.resume()` every 50 ms until the suite prints `DONE`. No RCON command ever blocks the game loop. A Lua error inside a step becomes a `FAIL` with its traceback; a chunk that does not compile shows up as `FAIL <file>: lua error`.

Helpers: `lab.check(name, cond, detail)`, `lab.info(text or LocalisedString)`, `lab.dev(fn, ...)` (`cybersyn-manager-dev`), `lab.read(...)` (`cybersyn` `read_global`), `lab.tab_keys(pi)` (row identities of every tab in display order), `lab.ordered(keys, n, ascending)`, `lab.subset`, `lab.same_list`, `lab.count`, `lab.set_of`, `lab.filter_cases(item)`, `lab.set_status_filter(pi, status)`, `lab.golden(pi)` (the fixed-tick golden groups below); shared tables `lab.SORTS`, `lab.DEFAULT_SORT`, `lab.STATUSES`, `lab.PERIODS`.

## The golden dispatch trace

The dev save does nothing on its own: by its boot tick every signal-A train is stuck on a cross-cluster dispatch and no signal-B request clears its threshold, so an unattended 3-minute trace is empty. At the window's start tick the recorder applies a fixed stimulus inside the tick handler:

- every item and fluid value of every constant combinator on `cyb-bench` × 10 (signal-B requests and provides clear their thresholds);
- an operator stands in for inserters and pumps: a train waiting at its provider gets its manifest inserted, a train waiting at its requester is emptied;
- the clusters are dead-end lines whose stops all face west-bound traffic, so a train cannot reach a stop or its depot east of it: a train in `no_path` gets one temporary rail waypoint at the east end of its line per leg (double-headed trains reverse at any record) and then reaches its target. Cybersyn ignores temporary rail records, as it does for Space Exploration's elevator waypoints.

Then every tick (no sampling interval, so nothing can fall between samples or depend on alignment) the recorder reads `read_global("trains")` and appends one event `[tick, train_id, field, value]` per change of `status`, `p`, `r`, `depot`, `available` and `manifest` (`hash=count,...` in manifest order; hash as `hash_item`: `name` or `name|quality`). Train ids are visited in sorted order. Missing values are `false`.

The window starts at a fixed tick (the baseline's `start`, 22200 on layout-dev; on `--record` the next whole 600 ticks at least 600 after boot) and lasts 10,800 ticks (3 game-minutes) at `game.speed` 20. Registration happens about 1,080 ticks before the start, so it never races the boot. At the window's last tick the same handler runs `collect()`, opens the manager and dumps every tab, so `summary.json` describes exactly that tick.

Each station's `deliveries_total` and `display_state` are traced the same way into `station_events` (read field by field with `read_global("stations", id, field)`; no measurable wall-time cost).

At HEAD 3b5fe31 the window holds 176 train events and 2,696 station events: 11 dispatches and 9 completed deliveries by trains 15 and 43, plus the stuck hub trains.

- Determinism: the trace is a pure function of the save and the mod (the game is deterministic, the handler runs inside the tick, nothing depends on when RCON commands arrive). Three fresh-boot runs produced the identical trace and summary.
- Sensitivity: flipping the provider distance tiebreak in `central-planning.lua` (`best_p_to_r_dist > best_dist` to `<`, in a scratch copy run with `MOD=`) diverges at event 42, tick 22275 (`p` 1123 instead of 1138), and changes the summary.

`summary.json` is written at the window's last tick by the same handler (`lab.golden` in `lib.lua`), one `compare.py` group each:

- `summary`: `summary()`; `tabs`: every tab's row keys under the default sort.
- `filters.<case>`: every tab's row keys under each filter case of `lab.filter_cases` (query, item, both networks, mask 2, both surfaces).
- `sorts.stations|trains.<column>.asc|desc`: row ids for every sort column in both directions, so tie order and key semantics are pinned, not only the default sort. `sorts.inventory.<column>.<dir>.<grid>`: hashes plus the raw sort keys (amounts and station counts as numbers, not captions).
- `stations`: each station's status by id, the chip counts, and the ids each status chip shows.
- `overview_model.<period>`: the Overview tiles model and each list's keys, order values and totals for 10, 60 and 1440 minutes. Phase 3 changes the tiles on purpose: re-record this group with a note in the commit.

Mutation probes at HEAD (scratch copies run with `MOD=`), each caught: network/mask filters made no-ops (`util.network_passes` returns true; the oracle checks and `filters.*`), starved stations reported saturated (`stations`), the collector tiebreak reduced to the id (`sorts.stations`), inventory amounts doubled (`sorts.inventory`).

Planner coverage is narrow: 11 dispatches by trains 15 and 43, so mask matching, priorities, layout filters and threshold edges are not exercised. Do not treat the golden trace as planner coverage; the phase-2 reason-code suite (PLAN3 §6.2) is where those branches get their cases.
 Fields named `tick` or `*_tick` may differ by up to 600 ticks (`compare.py` `TICK_TOLERANCE`); everything else, including the order of every key list, must match. Summary fields that are new since the baseline are reported as `INFO`, missing ones fail; a key that appears only in the run anywhere deeper (a new network in `available_by_network`, a new Overview list) fails, and so does a new top-level group.

## Baselines

`tests/baseline/dispatch-trace.json`, `summary.json` and `save.sha1` (the save they were recorded on; a different save fails the run).

Regenerate with `tests/lab/run.sh <scratch> <port> --record`, then run once more without `--record` to confirm green. That is legitimate only when a PLAN3 phase deliberately changes semantics (planner decisions per §4.8c, or what a summary field or dump means), and the commit that rewrites the baseline must say which change and why. A refactor that merely moves code must pass against the existing baseline; a divergence there is a bug.

## Measured limits (layout-dev, this machine, 2026-10-15)

- RCON command size (`lab.sh file`): no limit found. Files of 0.9 KB to 3.8 MB of Lua and a single 20 MB string literal were accepted and executed whole; responses of 8 MB came back whole. Files are sent as one command, nothing is chunked. The practical limit is `RCON_TIMEOUT` (120 s per command, `cyblab.py`).
- One `lab.sh cmd` round trip: about 65 ms (Python start plus RCON).
- Boot to RCON: 2 s. Trace window: 10,800 ticks in about 9 s at speed 20 (about 1,240 ticks/s).
- Whole run: about 14 s wall, against a 90 s budget (13.9 s with the station trace and `lab.golden`).
