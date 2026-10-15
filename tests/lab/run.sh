#!/bin/bash
# In-game characterization suite: boots a save headless with this worktree's mod, records the golden dispatch trace,
# runs every tests/lab/*_test.lua in sorted order and compares against tests/baseline/.
# usage: tests/lab/run.sh <scratch> <rcon port> [save.zip] [--record]
set -u
LAB=${LAB:-/home/daniel/factorio_20/manager-facelift/lab.sh}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MOD=${MOD:-$ROOT/cybersyn}
BASE="$ROOT/tests/baseline"
TRACE_LENGTH=${TRACE_LENGTH:-10800}
TRACE_SPEED=${TRACE_SPEED:-20}

RECORD=0
ARGS=()
for a in "$@"; do
	case "$a" in
		--record) RECORD=1 ;;
		*) ARGS+=("$a") ;;
	esac
done
if [ ${#ARGS[@]} -lt 2 ]; then
	echo "usage: $0 <scratch> <rcon port> [save.zip] [--record]" >&2
	exit 2
fi
SCRATCH=${ARGS[0]}
PORT=${ARGS[1]}
SAVE=${ARGS[2]:-/home/daniel/factorio_20/manager-facelift/saves/layout-dev.zip}
mkdir -p "$SCRATCH"
LOG="$SCRATCH/lab-run.log"
OUTPUT="$SCRATCH/cyblab/write-data/script-output/lab"
: > "$LOG"
T0=$(date +%s.%N)

lab() { "$LAB" "$SCRATCH" "$@"; }
stop_lab() { lab stop >> "$LOG" 2>&1; }
trap stop_lab EXIT

RESULTS="$SCRATCH/lab-results.txt"
: > "$RESULTS"
emit() { echo "$1" | tee -a "$RESULTS"; }

# Keeps PASS/FAIL/INFO lines; a Lua error from RCON (no protocol line) becomes a FAIL.
collect() {
	local name=$1 text=$2
	echo "$text" >> "$LOG"
	if grep -q '^Cannot execute command' <<< "$text"; then
		emit "FAIL $name: lua error: $(grep -m1 '^Cannot execute command' <<< "$text" | cut -c1-400)"
	fi
	grep -E '^(PASS|FAIL|INFO) ' <<< "$text" | while IFS= read -r line; do emit "$line"; done
}

wait_tick() { grep -oE '^WAIT [0-9]+' <<< "$1" | tail -1 | cut -d' ' -f2; }

# A suite asks for game time with WAIT <tick>; resume until it says DONE (or errors). A file that never calls
# lab.suite, or returns before its last step, prints no DONE and fails instead of passing with zero checks.
run_suite_output() {
	local name=$1 text=$2 guard=0 done=0 checks=0
	collect "$name" "$text"
	while :; do
		grep -q '^DONE ' <<< "$text" && done=1
		checks=$((checks + $(grep -cE '^(PASS|FAIL) ' <<< "$text")))
		[ -n "$(wait_tick "$text")" ] || break
		guard=$((guard + 1))
		if [ $guard -gt 2000 ]; then emit "FAIL $name: suite never finished waiting"; return; fi
		sleep 0.05
		text=$(lab cmd 'lab.resume()' 2>&1)
		collect "$name" "$text"
	done
	if [ $done -eq 0 ]; then
		emit "FAIL $name: suite did not finish (no DONE)"
	elif [ $checks -eq 0 ]; then
		emit "FAIL $name: suite ran no checks"
	fi
}

# Loose render budgets on layout-dev (about 10x what HEAD 3b5fe31 measured), parsed from the profiler text that
# 20_manager prints as "INFO 20_manager: update <tab> n=5 total ... avg Duration: <x>ms".
check_budgets() {
	local tab ms limit
	while IFS= read -r line; do
		tab=$(sed -E 's/^INFO 20_manager: update ([a-z_]+) .*/\1/' <<< "$line")
		ms=$(grep -oE 'avg [^0-9]*[0-9.]+ ?ms' <<< "$line" | grep -oE '[0-9.]+' | tail -1)
		[ -n "$ms" ] || { emit "FAIL budget $tab: no avg in '$line'"; continue; }
		limit=5
		[ "$tab" = overview ] && limit=3
		if python3 -I -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$ms" "$limit"; then
			emit "PASS budget: $tab update avg $ms ms < $limit ms"
		else
			emit "FAIL budget: $tab update avg $ms ms, budget $limit ms"
		fi
	done < <(grep -E '^INFO 20_manager: update ' "$RESULTS")
}

up=$(lab start "$MOD" "$PORT" "$SAVE" 2>&1)
echo "$up" >> "$LOG"
boot_tick=$(grep -oE 'up at tick [0-9]+' <<< "$up" | grep -oE '[0-9]+$')
# Seen once in back-to-back runs on one port: the first RCON login fails. One clean restart recovers.
if [ -z "$boot_tick" ] && grep -q 'RCON auth failed' <<< "$up"; then
	stop_lab
	sleep 2
	up=$(lab start "$MOD" "$PORT" "$SAVE" 2>&1)
	echo "$up" >> "$LOG"
	boot_tick=$(grep -oE 'up at tick [0-9]+' <<< "$up" | grep -oE '[0-9]+$')
fi
if [ -z "$boot_tick" ]; then
	echo "$up"
	emit "FAIL lab: server did not start"
	echo "PASS 0 FAIL 1"
	exit 1
fi
emit "INFO lab: $(basename "$SAVE") up at tick $boot_tick"

# The baselines describe one save; a re-saved dev save shifts every tick and decision.
save_sum=$(sha1sum "$SAVE" | cut -d' ' -f1)
if [ $RECORD -eq 0 ] && [ -f "$BASE/save.sha1" ] && [ "$(cut -d' ' -f1 "$BASE/save.sha1")" != "$save_sum" ]; then
	emit "FAIL baseline: $(basename "$SAVE") is not the save the baseline was recorded on ($(cat "$BASE/save.sha1"))"
fi

collect lib "$(lab file "$HERE/lib.lua" 2>&1)"

# The trace window starts at a fixed tick so every run records the same game time: the baseline's start tick, or
# on --record the next whole 10 s at least 10 s after boot.
start=""
if [ $RECORD -eq 0 ] && [ -f "$BASE/dispatch-trace.json" ]; then
	start=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["start"])' "$BASE/dispatch-trace.json")
fi
if [ -z "$start" ]; then
	start=$(( (boot_tick + 600 + 599) / 600 * 600 ))
fi
lab cmd "lab.trace_cfg = {start = $start, length = $TRACE_LENGTH, speed = $TRACE_SPEED, save = '$(basename "$SAVE")'}" >> "$LOG" 2>&1
collect dispatch_trace "$(lab file "$HERE/dispatch_trace.lua" 2>&1)"
deadline=$(( $(date +%s) + 120 ))
while :; do
	state=$(lab cmd 'rcon.print(lab.trace and (lab.trace.done and "done" or game.tick) or "missing")' 2>&1)
	[ "$state" = "done" ] && break
	if [ "$state" = "missing" ] || [ "$(date +%s)" -gt $deadline ]; then
		emit "FAIL dispatch_trace: recorder did not finish ($state)"
		break
	fi
	sleep 0.25
done
emit "INFO dispatch_trace: window done after $(python3 -I -c "import time; print(f'{time.time() - $T0:.1f}')") s"

for f in "$HERE"/*_test.lua; do
	name=$(basename "$f" .lua)
	run_suite_output "$name" "$(lab file "$f" 2>&1)"
done

if [ $RECORD -eq 1 ]; then
	mkdir -p "$BASE"
	echo "$save_sum $(basename "$SAVE")" > "$BASE/save.sha1"
	for kind in dispatch-trace summary; do
		if [ -f "$OUTPUT/$kind.json" ]; then
			python3 -I -c 'import json,sys; json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"), indent=1, sort_keys=True)' \
				"$OUTPUT/$kind.json" "$BASE/$kind.json"
			emit "INFO baseline: recorded $kind.json"
		else
			emit "FAIL baseline: $kind.json was not written"
		fi
	done
fi
check_budgets
python3 -I "$HERE/compare.py" "$BASE" "$OUTPUT" | while IFS= read -r line; do emit "$line"; done

stop_lab
trap - EXIT
pass=$(grep -c '^PASS ' "$RESULTS")
fail=$(grep -c '^FAIL ' "$RESULTS")
echo "wall $(python3 -I -c "import time; print(f'{time.time() - $T0:.1f}')") s, log $LOG"
echo "PASS $pass FAIL $fail"
[ "$fail" -eq 0 ]
