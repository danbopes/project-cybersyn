"""Compares the run's dispatch trace and summary against tests/baseline; prints PASS/FAIL/INFO lines for run.sh.

usage: compare.py <baseline dir> <script-output/lab dir>
"""
import json
import sys
from pathlib import Path

# Tick-valued fields move when a refactor shifts when a pass starts or ends; anything else must match exactly.
TICK_TOLERANCE = 600


def load(path: Path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def is_tick_key(key) -> bool:
    return isinstance(key, str) and (key == "tick" or key.endswith("_tick"))


def diff(base, cur, path, out, tick=False, extras=True):
    """Appends one line per difference. `extras` False tolerates keys only in the run at this level (not deeper)."""
    if isinstance(base, dict) and isinstance(cur, dict):
        for k in base:
            if k not in cur:
                out.append(f"{path}.{k}: missing (baseline {json.dumps(base[k])[:80]})")
            else:
                diff(base[k], cur[k], f"{path}.{k}", out, is_tick_key(k))
        if extras:
            for k in cur:
                if k not in base:
                    out.append(f"{path}.{k}: only in run ({json.dumps(cur[k])[:80]})")
        return
    if isinstance(base, list) and isinstance(cur, list):
        if len(base) != len(cur):
            out.append(f"{path}: {len(cur)} entries, baseline {len(base)}")
        for i, (b, c) in enumerate(zip(base, cur)):
            diff(b, c, f"{path}[{i}]", out)
        return
    # Lua's table_to_json writes an empty table as {} or [] depending on nothing we control.
    if base in ({}, []) and cur in ({}, []):
        return
    if tick and isinstance(base, (int, float)) and isinstance(cur, (int, float)):
        if abs(base - cur) > TICK_TOLERANCE:
            out.append(f"{path}: {cur}, baseline {base} (beyond {TICK_TOLERANCE} ticks)")
        return
    if base != cur:
        out.append(f"{path}: {json.dumps(cur)[:120]}, baseline {json.dumps(base)[:120]}")


def compare_events(name, b, c, start, stop):
    for i, (eb, ec) in enumerate(zip(b, c)):
        if eb != ec:
            print(f"FAIL {name}: first divergence at event {i}: got {ec}, baseline {eb}")
            return
    if len(b) != len(c):
        i = min(len(b), len(c))
        extra = (c if len(c) > len(b) else b)[i]
        print(f"FAIL {name}: {len(c)} events, baseline {len(b)}; first unmatched at {i}: {extra} "
              f"({'only in run' if len(c) > len(b) else 'only in baseline'})")
        return
    print(f"PASS {name} ({len(c)} events, ticks {start}..{stop})")


def compare_trace(base, cur):
    name = "30_dispatch_trace: golden trace"
    if base is None:
        print(f"FAIL {name}: no baseline (run with --record)")
        return
    if cur is None:
        print(f"FAIL {name}: the run wrote no dispatch-trace.json")
        return
    for key in ("start", "stop", "stimulus"):
        if base.get(key) != cur.get(key):
            print(f"FAIL {name}: {key} {cur.get(key)!r}, baseline {base.get(key)!r}")
            return
    compare_events(name, base["events"], cur["events"], cur["start"], cur["stop"])
    if "station_events" in base:
        compare_events("30_dispatch_trace: golden station trace", base["station_events"], cur.get("station_events") or [],
                       cur["start"], cur["stop"])


def compare_summary(base, cur):
    name = "30_dispatch_trace: summary baseline"
    if base is None:
        print(f"FAIL {name}: no baseline (run with --record)")
        return
    if cur is None:
        print(f"FAIL {name}: the run wrote no summary.json")
        return
    # One PASS/FAIL per group, so a failure names the area: summary, each tab's default rows, each filter case,
    # each sorted tab, station statuses, and the Overview model (which a phase that redesigns the tiles re-records).
    split = ("tabs", "filters", "sorts")
    groups = []
    for key in sorted(base):
        if key == "tick":
            continue
        if key in split and isinstance(base[key], dict):
            for sub in sorted(base[key]):
                groups.append((f"{key}.{sub}", base[key][sub], (cur.get(key) or {}).get(sub)))
            for sub in sorted(set(cur.get(key) or {}) - set(base[key])):
                print(f"FAIL {name} {key}.{sub}: only in run")
        else:
            groups.append((key, base[key], cur.get(key)))
    groups.append(("tick", base.get("tick"), cur.get("tick")))
    for label, b, c in groups:
        out = []
        if label == "tick":
            diff({"tick": b}, {"tick": c}, "", out)
        elif c is None:
            out.append(f"{label}: missing from the run")
        else:
            diff(b, c, label, out, extras=label != "summary")
        if out:
            more = f" (+{len(out) - 5} more)" if len(out) > 5 else ""
            print(f"FAIL {name} {label}: " + "; ".join(out[:5]) + more)
        else:
            print(f"PASS {name} {label}")
    extra = sorted(set((cur.get("summary") or {})) - set((base.get("summary") or {})))
    if extra:
        print(f"INFO 30_dispatch_trace: summary fields not in the baseline: {', '.join(extra)}")
    extra = sorted(set(cur) - set(base))
    if extra:
        print(f"FAIL {name}: groups not in the baseline: {', '.join(extra)} (re-record deliberately)")


def main() -> int:
    base_dir, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
    compare_trace(load(base_dir / "dispatch-trace.json"), load(out_dir / "dispatch-trace.json"))
    compare_summary(load(base_dir / "summary.json"), load(out_dir / "summary.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
