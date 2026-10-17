--By Mami

MISSING_TRAIN_NAME = "cybersyn-missing-train"
LOST_TRAIN_NAME = "cybersyn-lost-train"
NONEMPTY_TRAIN_NAME = "cybersyn-nonempty-train"

SIGNAL_PRIORITY = "cybersyn-priority"
REQUEST_THRESHOLD = "cybersyn-request-threshold"
REQUEST_FLUID_THRESHOLD = "cybersyn-fluid-request-threshold"
LOCKED_SLOTS = "cybersyn-locked-slots"
RESERVED_FLUID_CAPACITY = "cybersyn-reserved-fluid-capacity"

COMBINATOR_NAME = "cybersyn-combinator"
COMBINATOR_OUT_NAME = "cybersyn-combinator-output"
COMBINATOR_CLOSE_SOUND = "entity-close/cybersyn-combinator"
ALERT_SOUND = "utility/console_message"

MODE_DEFAULT = "*"
MODE_PRIMARY_IO = "/"
MODE_PRIMARY_IO_FAILED_REQUEST = "^"
MODE_PRIMARY_IO_ACTIVE = "<<"
MODE_SECONDARY_IO = "%"
MODE_SECONDARY_INVENTORY = "AND"
MODE_DEPOT = "+"
MODE_WAGON = "-"
MODE_REFUELER = ">>"

SETTING_DISABLE_ALLOW_LIST = 2
SETTING_IS_STACK = 3
SETTING_ENABLE_INACTIVE = 4
SETTING_USE_ANY_DEPOT = 5
SETTING_DISABLE_DEPOT_BYPASS = 6
SETTING_ENABLE_SLOT_BARRING = 7
SETTING_ENABLE_CIRCUIT_CONDITION = 8
SETTING_ENABLE_TRAIN_COUNT = 9
SETTING_ENABLE_MANUAL_INVENTORY = 10
SETTING_DISABLE_MANIFEST_CONDITION = 11

-- Default second_constant bits for newly placed combinators (bit flags).
-- Build a mask with set_flag(n) to make adding/removing defaults clear and safe.
local function set_flag(n) return bit32.lshift(1, n) end
COMBINATOR_DEFAULT_SECOND_CONSTANT = bit32.bor(
	set_flag(SETTING_ENABLE_TRAIN_COUNT),
	set_flag(SETTING_USE_ANY_DEPOT)
)

NETWORK_SIGNAL_DEFAULT = { name = "signal-A", type = "virtual" }
NETWORK_SIGNAL_GUI_DEFAULT = { name = "signal-each", type = "virtual" }
NETWORK_ANYTHING = "signal-anything"
NETWORK_EACH = "signal-each"
INACTIVITY_TIME = 100
LOCK_TRAIN_TIME = 60 * 60 * 60 * 24 * 7
NO_PATH_SKIP_TIME = 5 * 60 -- 5s

DELTA = 1 / 2048

DEPOT_PRIORITY_MULT = 2048

PROVIDER_ID_ITEM = "cybersyn-provider-id"
REQUESTER_ID_ITEM = "cybersyn-requester-id"
REFUELER_ID_ITEM = "cybersyn-refueler-id"

STATUS_D = 0
STATUS_TO_P = 1
STATUS_P = 2
STATUS_TO_R = 3
STATUS_R = 4
STATUS_TO_D = 5
STATUS_TO_D_BYPASS = 6
STATUS_TO_F = 7
STATUS_F = 8
STATUS_CUSTOM = 256 --this status and any status greater than it can be used by other mods (I've reserved the lower integers for myself in case I want to add more statuses)

FAILURE_REASON_NO_PROVIDER_STOCK = 0
FAILURE_REASON_NO_TRAIN_AVAILABLE = 1
FAILURE_REASON_TRAIN_CAPACITY = 2
FAILURE_REASON_LAYOUT_MISMATCH = 3

LONGEST_INSERTER_REACH = 2

STATE_INIT = 0
STATE_POLL_STATIONS = 1
STATE_DISPATCH = 2

DIFFERENT_SURFACE_DISTANCE = 1000000000

-- Diagnostics (scripts/diag.lua, PLAN3 §4.5). Reason codes name the tick_dispatch site that rejected a request.
-- Lost priority is a counter on an entry; P_RESERVED is the reason of a requester whose only provider was locked by
-- a requester evaluated ahead of it although it held enough for this one. There is no "no path" reason (the
-- planner never paths).
REASON_NO_PROVIDER = 1
REASON_R_AT_LIMIT = 2
REASON_R_DISABLED = 3
REASON_R_IS_PROVIDING = 4
REASON_P_AT_LIMIT = 5
REASON_P_IS_REQUESTING = 6
REASON_MASK_MISMATCH = 7
REASON_NO_SURFACE_ROUTE = 8
REASON_P_BELOW_THRESHOLD = 9
REASON_NO_TRAINS_ON_NETWORK = 10
REASON_TRAIN_FILTERED = 11
REASON_CAPACITY = 12
REASON_R_LAYOUT = 13
REASON_P_LAYOUT = 14
REASON_ALL_IN_INTERRUPT = 15
REASON_P_RESERVED = 16

REASON_NAMES = {
	"NO_PROVIDER", "R_AT_LIMIT", "R_DISABLED", "R_IS_PROVIDING", "P_AT_LIMIT", "P_IS_REQUESTING", "MASK_MISMATCH",
	"NO_SURFACE_ROUTE", "P_BELOW_THRESHOLD", "NO_TRAINS_ON_NETWORK", "TRAIN_FILTERED", "CAPACITY", "R_LAYOUT",
	"P_LAYOUT", "ALL_IN_INTERRUPT", "P_RESERVED",
}
--- Locale key suffix per reason: [cybersyn-diag] reason-<key>, chip-<key>, why-<key>, fix-<key>.
REASON_KEYS = {}
REASON_BY_NAME = {}
for code, name in ipairs(REASON_NAMES) do
	REASON_KEYS[code] = string.gsub(string.lower(name), "_", "-")
	REASON_BY_NAME[name] = code
end
--- Chip colour per reason: red = nothing will change on its own, orange = waiting on stock or capacity, grey = by
--- design (a setting of the player's). Also the order of "worst reason" for a station.
REASON_SEVERITY = {
	[REASON_NO_PROVIDER] = 3, [REASON_R_AT_LIMIT] = 2, [REASON_R_DISABLED] = 1, [REASON_R_IS_PROVIDING] = 1,
	[REASON_P_AT_LIMIT] = 2, [REASON_P_IS_REQUESTING] = 1, [REASON_MASK_MISMATCH] = 3, [REASON_NO_SURFACE_ROUTE] = 3,
	[REASON_P_BELOW_THRESHOLD] = 2, [REASON_NO_TRAINS_ON_NETWORK] = 3, [REASON_TRAIN_FILTERED] = 3,
	[REASON_CAPACITY] = 3, [REASON_R_LAYOUT] = 3, [REASON_P_LAYOUT] = 3, [REASON_ALL_IN_INTERRUPT] = 2,
	[REASON_P_RESERVED] = 2,
}

-- Rejection counters of one evaluation (an unserved entry's `rej`): the five provider sites in the order a provider
-- passes them, then the three causes of a train filtered at correctness 1.
REJ_P_AT_LIMIT = 1
REJ_P_IS_REQUESTING = 2
REJ_MASK_MISMATCH = 3
REJ_NO_SURFACE_ROUTE = 4
REJ_P_BELOW_THRESHOLD = 5
REJ_TRAIN_MASK = 6
REJ_TRAIN_MANUAL = 7
REJ_TRAIN_SURFACE = 8
REJ_COUNT = 8
REJ_NAMES = {
	"P_AT_LIMIT", "P_IS_REQUESTING", "MASK_MISMATCH", "NO_SURFACE_ROUTE", "P_BELOW_THRESHOLD", "TRAIN_MASK",
	"TRAIN_MANUAL", "TRAIN_SURFACE",
}
REJ_REASON = {
	REASON_P_AT_LIMIT, REASON_P_IS_REQUESTING, REASON_MASK_MISMATCH, REASON_NO_SURFACE_ROUTE, REASON_P_BELOW_THRESHOLD,
}

-- Event kinds of the two rings. Kinds 1-18 go to the basic ring, 19-25 (DIAG_KIND_FULL) only to the full ring.
-- short_load, unexpected_cargo, residual_cargo, schedule_edited, lint and manual_action are declared for the ring
-- schema; their hooks land in phase 2b.
DIAG_KIND_UNSERVED_REASON = 1
DIAG_KIND_SERVED = 2
DIAG_KIND_FLAPPING = 3
DIAG_KIND_DISPATCH_FAILED = 4
DIAG_KIND_DELIVERY_FAILED = 5
DIAG_KIND_ALERT = 6
DIAG_KIND_STATION_POWER = 7
DIAG_KIND_STATION_LIMIT = 8
DIAG_KIND_STATION_WARMUP_DONE = 9
DIAG_KIND_STATION_DISABLED = 10
DIAG_KIND_SHORT_LOAD = 11
DIAG_KIND_UNEXPECTED_CARGO = 12
DIAG_KIND_RESIDUAL_CARGO = 13
DIAG_KIND_SCHEDULE_EDITED = 14
DIAG_KIND_LINT = 15
DIAG_KIND_ACKNOWLEDGED = 16
DIAG_KIND_UNACKNOWLEDGED = 17
DIAG_KIND_MANUAL_ACTION = 18
DIAG_KIND_DISPATCHED = 19
DIAG_KIND_ARRIVE_P = 20
DIAG_KIND_LEAVE_P = 21
DIAG_KIND_ARRIVE_R = 22
DIAG_KIND_LEAVE_R = 23
DIAG_KIND_RETURNED = 24
DIAG_KIND_TRAIN_STATE = 25
DIAG_KIND_NAMES = {
	"unserved_reason", "served", "flapping", "dispatch_failed", "delivery_failed", "alert", "station_power",
	"station_limit", "station_warmup_done", "station_disabled", "short_load", "unexpected_cargo", "residual_cargo",
	"schedule_edited", "lint", "acknowledged", "unacknowledged", "manual_action", "dispatched", "arrive_p", "leave_p",
	"arrive_r", "leave_r", "returned", "train_state",
}
--- Locale key suffix per kind: [cybersyn-diag] kind-<key>.
DIAG_KIND_KEYS = {}
for kind, name in ipairs(DIAG_KIND_NAMES) do
	DIAG_KIND_KEYS[kind] = string.gsub(name, "_", "-")
end
DIAG_KIND_FULL = {
	[DIAG_KIND_DISPATCHED] = true, [DIAG_KIND_ARRIVE_P] = true, [DIAG_KIND_LEAVE_P] = true,
	[DIAG_KIND_ARRIVE_R] = true, [DIAG_KIND_LEAVE_R] = true, [DIAG_KIND_RETURNED] = true,
	[DIAG_KIND_TRAIN_STATE] = true,
}

DIAG_SEV_ERROR = 1
DIAG_SEV_WARNING = 2
DIAG_SEV_INFO = 3
DIAG_SEV_NAMES = { "error", "warning", "info" }

-- `code` of an alert event: the alert that was sent. 1-10 match the ids active_alerts already uses.
DIAG_ALERT_STUCK = 1
DIAG_ALERT_NONEMPTY_IN_DEPOT = 2
DIAG_ALERT_DEPOT_BROKEN = 3
DIAG_ALERT_STATION_BROKEN = 4
DIAG_ALERT_REFUELER_BROKEN = 5
DIAG_ALERT_AT_INCORRECT_STATION = 6
DIAG_ALERT_CANNOT_PATH_BETWEEN_SURFACES = 7
DIAG_ALERT_GROUP_SCHEDULE_BROKEN = 8
DIAG_ALERT_SCHEDULE_BROKEN = 9
DIAG_ALERT_UNEXPECTED_CARGO = 10
DIAG_ALERT_MISSING_TRAIN = 11
DIAG_ALERT_NO_TRAIN_HAS_CAPACITY = 12
DIAG_ALERT_NO_TRAIN_MATCHES_R_LAYOUT = 13
DIAG_ALERT_NO_TRAIN_MATCHES_P_LAYOUT = 14
DIAG_ALERT_NON_DEFAULT_PRIORITY = 15
DIAG_ALERT_UNEXPECTED_TRAIN = 16
DIAG_ALERT_TRAINS_FILTERED = 17
DIAG_ALERT_NAMES = {
	"stuck", "nonempty_in_depot", "depot_broken", "station_broken", "refueler_broken", "at_incorrect_station",
	"cannot_path_between_surfaces", "group_schedule_broken", "schedule_broken", "unexpected_cargo", "missing_train",
	"no_train_has_capacity", "no_train_matches_r_layout", "no_train_matches_p_layout", "non_default_priority",
	"unexpected_train", "trains_filtered",
}

-- `code` of a dispatch_failed event (create_delivery gave up after the planner chose a train).
DIAG_DISPATCH_TRAIN_INVALID = 1
DIAG_DISPATCH_DEPOT_INVALID = 2
DIAG_DISPATCH_PROVIDER_INVALID = 3
DIAG_DISPATCH_REQUESTER_INVALID = 4
DIAG_DISPATCH_SCHEDULE_REJECTED = 5
DIAG_DISPATCH_NAMES = { "train_invalid", "depot_invalid", "provider_invalid", "requester_invalid", "schedule_rejected" }

-- `code` of a delivery_failed event: who ended the delivery.
DIAG_FAIL_TRAIN_REMOVED = 1
DIAG_FAIL_EARLY_TO_DEPOT = 2
DIAG_FAIL_REMOTE = 3
DIAG_FAIL_NAMES = { "train_removed", "early_to_depot", "remote_interface" }

-- `code` of acknowledged/unacknowledged events: what was acknowledged; `b` of unacknowledged: why it ended.
DIAG_ACK_REQUEST = 1
DIAG_ACK_STATION = 2
DIAG_ACK_LINT = 3
DIAG_ACK_KINDS = { "request", "station", "lint" }
DIAG_ACK_END_EXPIRED = 1
DIAG_ACK_END_REASON_CHANGED = 2
DIAG_ACK_END_RESOLVED = 3
DIAG_ACK_END_MANUAL = 4

-- Setup lint (scripts/lint.lua, PLAN3 §4.12). A check is an index 1..LINT_COUNT; its bit in a subject's mask is
-- LINT_BIT[check]. Acknowledgements and the lint ring event (`a`) carry the index, so an index is never reused or
-- renumbered. The combinator and stop-name checks (derelict, ghost, no combinator, wrong side, double, name overlap)
-- come from the setup registry the build handlers keep; the others from the chunked job over storage and the
-- snapshot. LINT_MASK is "no network bit" (mask 0 on a network that has trains).
LINT_CAPACITY = 1
LINT_LAYOUT = 2
LINT_MASK = 3
LINT_NO_PROVIDER = 4
LINT_LIMIT_ZERO = 5
LINT_SAME_ITEM = 6
LINT_OCCUPANCY = 7
LINT_PHANTOM = 8
LINT_DEPOT_LIMIT = 9
LINT_DEPOT_SHARED_NAME = 10
LINT_REFUELER_MASK = 11
LINT_NEVER_REFUELLED = 12
LINT_IN_GROUP = 13
LINT_MISSING_STOP = 14
LINT_CAPACITY_DRIFT = 15
LINT_DERELICT_COMB = 16
LINT_GHOST_COMB = 17
LINT_NO_COMB = 18
LINT_WRONG_SIDE = 19
LINT_DOUBLE_COMB = 20
LINT_PRIORITY = 21
LINT_NAME_OVERLAP = 22
LINT_TRAIN_MASK = 23
LINT_NO_TRAIN = 24
LINT_COUNT = 24
LINT_NAMES = {
	"capacity", "layout", "mask", "no_provider", "limit_zero", "same_item", "occupancy", "phantom", "depot_limit",
	"depot_shared_name", "refueler_mask", "never_refuelled", "in_group", "missing_stop", "capacity_drift",
	"derelict_comb", "ghost_comb", "no_comb", "wrong_side", "double_comb", "priority", "name_overlap", "train_mask",
	"no_train",
}
LINT_BY_NAME = {}
--- Locale key suffix per check: [cybersyn-diag] lint-<key> (caption) and lint-fix-<key> (fix line).
LINT_KEYS = {}
LINT_BIT = {}
for check, name in ipairs(LINT_NAMES) do
	LINT_BY_NAME[name] = check
	LINT_KEYS[check] = string.gsub(name, "_", "-")
	LINT_BIT[check] = 2 ^ (check - 1)
end
--- The reason code a check predicts on a requester (PLAN3 §4.12); nil for checks about setups the dispatcher has no
--- reason for. LINT_PREDICTS_P holds the provider's where it differs (lint.predicts).
LINT_PREDICTS = {
	[LINT_CAPACITY] = REASON_CAPACITY,
	[LINT_LAYOUT] = REASON_R_LAYOUT,
	[LINT_MASK] = REASON_MASK_MISMATCH,
	[LINT_TRAIN_MASK] = REASON_TRAIN_FILTERED,
	[LINT_NO_TRAIN] = REASON_NO_TRAINS_ON_NETWORK,
	[LINT_NO_PROVIDER] = REASON_NO_PROVIDER,
	[LINT_LIMIT_ZERO] = REASON_R_DISABLED,
	[LINT_SAME_ITEM] = REASON_R_IS_PROVIDING,
	[LINT_PHANTOM] = REASON_R_AT_LIMIT,
	[LINT_CAPACITY_DRIFT] = REASON_CAPACITY,
}
LINT_PREDICTS_P = {
	[LINT_LAYOUT] = REASON_P_LAYOUT,
	[LINT_LIMIT_ZERO] = REASON_P_AT_LIMIT,
	[LINT_SAME_ITEM] = REASON_P_IS_REQUESTING,
	[LINT_PHANTOM] = REASON_P_AT_LIMIT,
}
--- DIAG_SEV_* per check: the ones that guarantee a request is never served are errors.
LINT_SEVERITY = {}
for check = 1, LINT_COUNT do LINT_SEVERITY[check] = DIAG_SEV_WARNING end
LINT_SEVERITY[LINT_CAPACITY] = DIAG_SEV_ERROR
LINT_SEVERITY[LINT_LAYOUT] = DIAG_SEV_ERROR
LINT_SEVERITY[LINT_TRAIN_MASK] = DIAG_SEV_ERROR
LINT_SEVERITY[LINT_NO_TRAIN] = DIAG_SEV_ERROR
LINT_SEVERITY[LINT_NO_PROVIDER] = DIAG_SEV_ERROR
LINT_SEVERITY[LINT_PHANTOM] = DIAG_SEV_ERROR
LINT_SEVERITY[LINT_NEVER_REFUELLED] = DIAG_SEV_INFO
LINT_SEVERITY[LINT_PRIORITY] = DIAG_SEV_ERROR
LINT_SEVERITY[LINT_DOUBLE_COMB] = DIAG_SEV_ERROR
LINT_SUBJECT_STATION = 1
LINT_SUBJECT_DEPOT = 2
LINT_SUBJECT_REFUELER = 3
LINT_SUBJECT_TRAIN = 4
LINT_SUBJECT_STOP = 5
LINT_SUBJECT_COMBINATOR = 6
LINT_SUBJECT_NAMES = { "station", "depot", "refueler", "train", "stop", "combinator" }
-- `code` of a lint event: the finding appeared or cleared.
DIAG_LINT_APPEARED = 1
DIAG_LINT_CLEARED = 2

-- `a` of a manual_action event: what a state-changing command or action did.
ACTION_FIX_PRIORITIES = 1
ACTION_ABOLISH_SAME_DEPOT = 2
ACTION_RECALCULATE_TRAIN_SIZE = 3
ACTION_FAIL_DELIVERY = 4
ACTION_RESCAN_STATION = 5
ACTION_REFRESH_ALLOW_LISTS = 6
ACTION_TEST_PATH = 7
ACTION_NAMES = { "fix_priorities", "abolish_same_depot", "recalculate_train_size", "fail_delivery", "rescan_station",
	"refresh_allow_lists", "test_path" }
