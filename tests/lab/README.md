# In-game characterization suite

Proves the manager GUI and the Cybersyn planner behave the same before and after a refactor. It boots the fast dev save headless, records a golden dispatch trace, drives the manager through its dev remote interface and compares against `tests/baseline/`.

```
tests/lab/run.sh <scratch> <rcon port> [save.zip] [--record]
```

- `<scratch>`: the lab's scratch dir (one lab per scratch dir and port; the game port is rcon + 7000).
- `save.zip`: defaults to `~/factorio_20/manager-facelift/saves/layout-dev.zip`. The suite's expectations (30 stations, 6 trains, the `cyb-bench` stimulus) belong to that save; other saves boot but will fail those checks.
- `--record`: rewrite `tests/baseline/` from this run (see below).
- Prints one `PASS`/`FAIL`/`INFO` line per check and a `SKIP <suite>: <check> (<why>)` line for each check whose subject does not exist yet, then `SKIP k` and `PASS n FAIL m`; exits non-zero on any failure (a SKIP is not a failure). A test file that prints no `DONE` (never calls `lab.suite`, or returns early) or runs no checks fails. A first RCON login that fails is retried once with a fresh start. The full RCON transcript is in `<scratch>/lab-run.log`, the result lines in `<scratch>/lab-results.txt`.
- Environment overrides: `MOD=<mod root>` (default: the `cybersyn/` next to `tests/`), `LAB=<lab.sh>`, `TRACE_LENGTH` (ticks, default 10800), `TRACE_SPEED` (default 20). Changing `TRACE_LENGTH` makes the trace incomparable with the baseline.

## What runs, in order

1. `lab.sh start` with the worktree's mod root, then `lib.lua` (helpers in the level-scope global `lab`).
2. `dispatch_trace.lua`, the golden trace recorder, before anything can touch the world. The runner polls until the window is done (about 10 s wall). Then `cases.lua` (the scenario constructors of the reason-code suite, global `cases`; defines functions only).
3. Every `tests/lab/*_test.lua` in sorted order:
   - `10_smoke_test.lua`: `remote.call("aitest", "run_all")`, one check per aitest test, `check_dispatch` all true. aitest builds a station on nauvis; the suite destroys the entities it added (with `raise_destroy`) so later suites see the save's 30 stations again.
   - `20_manager_test.lua`: freezes the planner (`cybersyn-enable-planner` off, restored at the end) so no new dispatch reshuffles rows between dumps; every tab renders (`update(pi, 5)`, timings as `INFO`); dump order identical 2 s apart; every sort column ascending and descending is ordered by the dumped key values; inventory captions match the aggregate (`stale == 0`) and every aggregated item is shown; filters (query, item, network, mask, surface) never add a row, and the network/mask filters keep exactly the stations an oracle computed from Cybersyn's own `stations` table (and do narrow); each status chip shows exactly the stations of that status in the unfiltered order, with its count; striping; paging bounds and clamping; `set_period` 10/60/1440 with every Overview list's rendered rows matching its model rows; hover on a station row holds, leave releases; pause freezes `last_update_tick`; heap growth over a full `bench_pass` under 10,000 KB; summary invariants.
   - `30_dispatch_trace_test.lua`: in-game sanity of the recorded trace (registered in time, dispatches and completed deliveries happened, operator acted).
   - `40_reason_codes_test.lua`: one constructed scenario per planner failure reason (PLAN3 §4.5, §6 gate 2), see "Reason-code scenarios" below. Runs last, builds everything far from the save's world and removes it again.
4. Render budgets: `run.sh` parses the `update <tab>` timings and fails Overview at 3 ms or more and any other tab at 5 ms or more (about 6x to 400x what HEAD measures on layout-dev, so only a gross regression trips them; the real budgets are on pY, PLAN3 §2.11).
5. `compare.py` compares `script-output/lab/dispatch-trace.json` and `summary.json` with `tests/baseline/` and prints the first divergence.

## The suite protocol

Each RCON command is its own chunk, so state lives in the global `lab`. A test file calls `lab.suite(name, steps)`. A step that needs game time calls `lab.wait(ticks[, speed])` and returns; the file prints `WAIT <tick>` and the RCON call ends, so the server keeps ticking (at `game.speed` 20 during waits). The runner then calls `lab.resume()` every 50 ms until the suite prints `DONE`. No RCON command ever blocks the game loop. A Lua error inside a step becomes a `FAIL` with its traceback; a chunk that does not compile shows up as `FAIL <file>: lua error`.

`lab.wait_until(cond, max_ticks[, speed])` is `lab.wait` that ends early once `cond()` is true (checked on every `lab.resume()`); the next step must check the condition itself.

Helpers: `lab.check(name, cond, detail)`, `lab.skip(name, why)` (prints `SKIP <suite>: name (why)`), `lab.info(text or LocalisedString)`, `lab.dev(fn, ...)` (`cybersyn-manager-dev`), `lab.read(...)` (`cybersyn` `read_global`), `lab.tab_keys(pi)` (row identities of every tab in display order), `lab.ordered(keys, n, ascending)`, `lab.subset`, `lab.same_list`, `lab.count`, `lab.set_of`, `lab.filter_cases(item)`, `lab.set_status_filter(pi, status)`, `lab.golden(pi)` (the fixed-tick golden groups below); shared tables `lab.SORTS`, `lab.DEFAULT_SORT`, `lab.STATUSES`, `lab.PERIODS`.

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
- Whole run: about 14 s wall, against a 90 s budget (13.9 s with the station trace and `lab.golden`); 15.8 to 17.4 s with the reason-code suite (1.7 s of it, 20 scenarios).

## Reason-code scenarios (`cases.lua`, `40_reason_codes_test.lua`)

One scenario per reason code of PLAN3 §4.5, written before the diagnostics core (`scripts/diag.lua`) exists. Today every scenario's observable checks show the situation it is built for (the requester asks, a provider offers the item at the requester's threshold unless the provider's stock is the point, the precondition holds) and that the planner does not serve it; which `tick_dispatch` site rejects it is only checked against the core's dev API once that API is there.

### Construction

`cases.<NAME>({k = row})` builds a self-contained scenario and returns `{name, expect, r_station, p_station, item, network, trains, cleanup, ...}` (`cases.lua` header lists every field). Each scenario gets:

- its own row on `cyb-bench` at `y = 2040 + 32 k` (the save's world ends at `y` 129): 330 tiles of straight east-west rail, substations and an electric energy interface. No row shares rail or poles with another or with the save.
- its own network name, a virtual signal nobody else uses (`signal-C` … `signal-V`), so the planner never matches it with the save's `signal-A`/`signal-B` stations or with another scenario (Cybersyn keys requests, providers and available trains by network name).
- its own depot at the east end and its own trains (locomotive, cargo wagon, locomotive: 40 stacks), built east of the depot and driving there on their own. All stops face west, as in the benchmark world: providers sit west of the depot and requesters west of the providers, so every leg is west-bound.
- stops built like `harness/benchmarks/cybersyn/build.lua` (Cybersyn combinator 1.5 east and 2.5 north of the stop, so the stop is in its search box, constant combinator wired red to its input, `second_constant` bits 0/1/2 for both/provide/request plus 4 for "disable allow list") and promoted out of warm-up through `write_global`, as `harness/suites/cybersyn.lua` does.

Because the scenarios cannot see each other they are all built at once; the whole file takes about 4,300 game ticks, 1.7 s wall.

A scenario is switched on in stages, one per planner cycle, each once its condition holds (a train parked, a delivery created). The last stage always switches on the request under test, so the key (requester, item) is never evaluated before the scenario is complete. A train that has to hold a delivery open (a train limit or a station's delivery counter) has its fuel taken out at the depot before it is dispatched: the planner does not look at fuel, and the train never leaves.

### Runner

A handler on Cybersyn's `tick_init` event counts planner cycles (and keeps the longest cycle seen); an `on_tick` handler advances the scenarios and samples them on the first tick after each cycle boundary, so every sample describes whole dispatcher cycles and nothing depends on when RCON commands arrive. For each scenario: arm, take the first sample after the cycle in which the request was first evaluated, wait at least two more cycles and 2,400 ticks (the 30 s flap window plus 10 s), take the settled sample (with `diag_counts`, while the cause is still in place) and evaluate the preconditions, then lift the cause where the scenario has one, wait for the delivery and two more cycles. A delivery is any `on_train_status_changed` to status 1 (to provider) whose train goes to the requester with the item in its manifest. Teardown destroys every entity with `raise_destroy`, deletes the second surface and compares Cybersyn's `stations`, `trains`, `depots`, `available_trains`, `layouts`, `refuelers`, warm-up queue, live `active_station_ids`, `connected_surfaces` and the surface list with a fingerprint taken before the suite (and checks 30 stations and an empty scenario area). The `stats` counters keep the scenarios' deliveries, as they would a player's.

Checks for every scenario, today: every stop is registered, it arms, its preconditions (below; every scenario except NO_PROVIDER and P_BELOW_THRESHOLD also checks that its provider polled the item at no less than the requester's `r_threshold`), the requester's combinator shows a failed request (`display_state` bit 2) and no delivery reached the requester while the cause was in place. A constructor that throws is one FAIL line `<NAME>: scenario builds`.

### When the diagnostics core lands

Detected by `remote.interfaces["cybersyn-manager-dev"].diag_unserved`. Without it each scenario prints `SKIP 40_reason_codes: <NAME> (no diag api)`; if the `cybersyn-diagnostics` setting exists (the core has landed) but that function does not, the suite FAILs instead of skipping. With it the runner sets `cybersyn-diagnostics` to `basic`, calls `diag_reset`, and per scenario checks:

- right after the first failing evaluation: `diag_unserved(r_station)[item].pending == expect`, or `reason == expect` with no pending (PLAN3 lets a key's first entry take effect at once); for LOST_PRIORITY instead `lost_n >= 1` and `lost_to == hi`;
- after the flap window: `reason == expect` (or the scenario's `expect_settled`), and `diag_counts()[reason] >= 1` read at that same sample;
- the payload numbers `a`/`b` (PLAN3 §4.5 B1) where they are defined, at the settled sample: R_AT_LIMIT 1/1, P_AT_LIMIT 1/1, P_BELOW_THRESHOLD 500/2,000, CAPACITY 50/40 (slots needed / largest capacity), NO_SURFACE_ROUTE the provider's and the requester's surface index (either order), NO_TRAINS_ON_NETWORK and both LOST_PRIORITY cases 0/0, TRAIN_FILTERED_MANUAL and _MASK 1/0 (available / usable); TRAIN_FILTERED_SCHEDULE `b == 0` at the first sample;
- the TRAIN_FILTERED cause split in `rej`: TRAIN_FILTERED_MASK counts under `TRAIN_MASK`, _MANUAL and _SCHEDULE under `TRAIN_MANUAL`, and nothing under the other two of `TRAIN_MASK`, `TRAIN_MANUAL`, `TRAIN_SURFACE`;
- the flap rule on TRAIN_FILTERED_SCHEDULE, the one scenario where the dispatcher itself changes the reason: a sample after the first shows `reason` TRAIN_FILTERED with NO_TRAINS_ON_NETWORK pending, and NO_TRAINS_ON_NETWORK is confirmed at least one cycle and 1,800 ticks (less two of the longest cycles, the sampling error) later;
- after a lift: a `served` event for the requester that is lifted (hi for LOST_PRIORITY) with a `seq` above `diag_state().seq` taken before the lift, and no unserved entry left for it;
- after teardown: `diag_unserved` is empty for every removed stop.

The dev-API contract these checks rely on (p2 brief deliverable 5, plus what it leaves open, settled here):

- `diag_counts()` counts live unserved entries by their confirmed reason (the number the Overview and the HUD line show), not evaluations; the suite reads it while the cause is in place.
- `diag_events(from_seq, limit)` may treat `from_seq` as inclusive or exclusive: the suite asks from `seq` and drops events with a `seq` not above it. `kind` is the string `"served"` or an integer that `diag_state().kinds` maps to it; `station` is the requester's unit number; `diag_unserved` is keyed by the item hash (`"iron-plate"`).
- LOST_PRIORITY: when an item's requester loop ends at the r591 return, every requester that lost a requester pick on priority during that call (skipped at the `prior < best_r_prior` goto, or picked and then replaced by a higher priority) gets `lost_n += 1` and `lost_to` = the requester that beat it; the dispatch success path records nothing. Both polling orders are built (LOST_PRIORITY, LOST_PRIORITY_LO_FIRST), so a core that only counts at the goto fails the second.
- TRAIN_FILTERED's `rej` split uses the keys `TRAIN_MASK` (the train's mask shares no bit), `TRAIN_MANUAL` (manual mode, or a schedule `validate_train_base_schedule` rejects) and `TRAIN_SURFACE` (`is_delivery_allowed_for_train` false).

Validated against a throwaway stub of the dev API written to that contract and PLAN3 §4.5 (a scratch copy of the mod, not committed: live counts, losses applied only at r591, exclusive `from_seq`, first entry immediate, flap rule, a/b and the `rej` split): every reason check passes. Mutation probes on the stub, each caught: the flap rule confirming at once (2 FAILs on TRAIN_FILTERED_SCHEDULE), manual rejections counted as mask (2), losses counted only at the goto (LOST_PRIORITY_LO_FIRST, 2), CAPACITY's a/b swapped (1), a destroyed stop's entries never removed (teardown, 1), the setting present without the dev API (1); an inclusive `from_seq` passes, as it should. Earlier probes against the first stub: the planner ignoring a zero network mask (MASK_MISMATCH gets a delivery) and correctness 5 classified as a layout mismatch (bug B3: ALL_IN_INTERRUPT reads R_LAYOUT).

Adding the `cybersyn-diagnostics` setting alone (a copy of the mod with only that setting, nothing else changed) moves the golden trace on layout-dev: first divergence at event 36, tick 22259 instead of 22265. The phase that adds the setting re-records the baseline with that note.

### The scenarios

Item `iron-plate` unless noted; "request N/T" is a requester signal of -N with a `cybersyn-request-threshold` of T.

**CONTROL** (no code). Provider 5,000, requester 2,000/1,000, one train. The runner stands in for inserters: loads the manifest at the provider, empties the train at the requester (and clears its request, since its combinator never sees stock arrive), and sends it round the east end of the line when it has no path home (as `dispatch_trace.lua` does). Checks: exactly one delivery when the case settles and still one when the trip is over, the train reached provider and requester, the delivery completed and the train is back at its depot and available. This is what makes "no delivery" in every other scenario meaningful.

**NO_PROVIDER**. The network's only provider offers copper plates; the requester asks for iron 2,000/1,000. Preconditions: the requester polled iron as requested; the provider polls copper but no iron. Lift: the provider also offers iron 5,000; the requester must be served.

**R_AT_LIMIT**. Requester with train limit 1. First it requests copper from one provider; the only train is dispatched and held (no fuel), so the requester has one delivery inbound. A second depot and train are built, then the requester also requests iron (another provider has 5,000). Preconditions: `trains_limit` 1, `deliveries_total` 1, the second train available.

**R_DISABLED**. Requester with train limit 0 requests 2,000/1,000; provider 5,000; one train. Precondition: `trains_limit` 0 in Cybersyn's station. Lift: the limit is removed; the requester must be served.

**R_IS_PROVIDING**. Stop A (provide and request) provides 5,000; requester B takes 2,000 and the train is held, so A has a pickup of iron in progress. Then B stops requesting, a second provider C offers 5,000, a second train arrives, and A requests 3,000/1,000. Preconditions: A's `deliveries[iron]` < 0 (C offering iron is the common check).

**LOST_PRIORITY** (a counter, not a reason; settles on NO_TRAINS_ON_NETWORK). Provider with exactly 2,000; requesters "hi" (`cybersyn-priority` 10) and "lo" (0) both 2,000/2,000, hi ahead of lo in the polling queue; the network's depot has no train. Every cycle the planner picks hi, fails it for want of a train and only then evaluates lo, so the item's requester loop ends at the r591 return with lo having lost to hi (the requester-side recording site of PLAN3 §4.5; with a train, hi's success would end the call on the dispatch path, where nothing is recorded). Preconditions: priorities 10 and 0, hi polled before lo, no train on the network. Lift: a train is built at the depot; hi is served exactly once and lo never is (the stock is one delivery). With the core: `lost_n >= 1` and `lost_to == hi` after the first evaluation, reason NO_TRAINS_ON_NETWORK, a served event for hi.

**LOST_PRIORITY_LO_FIRST**. The same with lo ahead of hi in the polling queue: the planner picks lo first and replaces it with hi, so lo never reaches the priority goto; the loss must be counted all the same.

**P_AT_LIMIT**. Provider (10,000) with train limit 1 serves requester 1; the train is held. A second train arrives, then requester 2 asks for 2,000/1,000. Preconditions: the provider is at 1 of 1, the second train is available.

**P_IS_REQUESTING**. Stop Q (provide and request) requests 2,000 from provider P0; the train is held, so Q has iron inbound. Then P0 stops providing, Q provides 5,000 (the network's only provider), a second train arrives, and requester R asks for 2,000/1,000. Preconditions: Q's `deliveries[iron]` > 0, Q is the only provider polled with iron.

**MASK_MISMATCH**. Requester mask 1, provider mask 2 (the network signal's value on each combinator), depot mask 3 so the train serves both. Preconditions: the masks in Cybersyn's stations and train.

**NO_SURFACE_ROUTE**. The provider stands on `rc-island`, a flat surface the test creates (and deletes); the requester and the train are on `cyb-bench`. No surface connection exists. The brief asked for the requester on nauvis; on layout-dev nauvis is natural terrain with an enemy base and no stations, so this follows PLAN3 §6.2 instead ("the `cyb-bench` surface plus a second surface created by the test"). Preconditions: the two stops are on different surfaces, `connected_surfaces` is empty.

**P_BELOW_THRESHOLD**. Provider 500, requester 3,000/2,000. Precondition: the provider polled 500. Lift: the provider goes to 5,000; the requester must be served.

**NO_TRAINS_ON_NETWORK**. Provider, requester and a depot with no train. Precondition: `available_trains[network]` is nil.

**TRAIN_FILTERED_MANUAL** (expects TRAIN_FILTERED). The only train is switched to manual mode at its depot; Cybersyn keeps it available (a manual switch is not a departure). Precondition: manual and still available.

**TRAIN_FILTERED_MASK** (expects TRAIN_FILTERED). Stations mask 1, depot (train) mask 2. Precondition: the three masks, the train available.

**TRAIN_FILTERED_SCHEDULE** (expects TRAIN_FILTERED, settles on NO_TRAINS_ON_NETWORK). The only train's schedule is cleared under manual control and the train is handed back one cycle later, so Cybersyn never sees a departure and keeps it available with no records. The first evaluation rejects it (`validate_train_base_schedule`) and also removes it from Cybersyn, so from the second evaluation on the network has no train. Preconditions: the schedule is empty, the planner dropped the train. The chip a player then sees ("No train", 0 of a fleet of 0) points away from the broken schedule; whether the core keeps TRAIN_FILTERED there is a phase-2 decision, and `expect_settled` follows it.

**CAPACITY**. Requester 10,000/5,000 (50 stacks), provider 20,000, the only train carries 40 stacks. Precondition: the train's `item_slot_capacity` 40 and the requester's threshold 5,000.

**R_LAYOUT**. The requester has "disable allow list" off and no inserters, so it accepts no layout with a cargo wagon; the provider accepts all. Preconditions: requester rejects, provider accepts the train's layout.

**P_LAYOUT**. The same with the roles swapped.

**ALL_IN_INTERRUPT**. The only train gets an always-true interrupt (iron plates ≥ 0) whose target is its own depot with a one-hour inactivity wait. When it fires at the depot, Cybersyn's `set_depot_schedule` takes the interrupt's record for its own depot record and keeps it as the only record, so the train is parked, available and inside an interrupt. (An interrupt to any other stop makes the train leave its depot, and Cybersyn drops a train that leaves its depot without a delivery; interrupts do not fire on Cybersyn's temporary records.) Precondition: the train is available and its current record has `created_by_interrupt`.
