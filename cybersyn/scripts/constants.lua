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
-- Lost priority is a counter on an entry, not a reason; there is no "no path" reason (the planner never paths).
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

REASON_NAMES = {
	"NO_PROVIDER", "R_AT_LIMIT", "R_DISABLED", "R_IS_PROVIDING", "P_AT_LIMIT", "P_IS_REQUESTING", "MASK_MISMATCH",
	"NO_SURFACE_ROUTE", "P_BELOW_THRESHOLD", "NO_TRAINS_ON_NETWORK", "TRAIN_FILTERED", "CAPACITY", "R_LAYOUT",
	"P_LAYOUT", "ALL_IN_INTERRUPT",
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
