class_name SettingsData
extends RefCounted

## Persistent app settings stored in user://settings.json.

const SETTINGS_PATH := "user://settings.json"

# --- Element placement (metres) --------------------------------------------
# Single source of truth for where in-world content lands when placed in front
# of the user. Each offset is a Vector3 in a camera-relative, gravity-aligned
# frame: X = the user's right, Y = up (true vertical), Z = forward (the direction
# the user faces, projected onto the horizontal plane — head pitch/roll ignored).
# So (0, -0.05, 0.8) reads as "0.8 m ahead, 5 cm below eye level, dead centre";
# give X a non-zero value to nudge an element to one side.
# Kept as constants, not saved settings, so tuning these here always takes effect
# (a value persisted to settings.json would otherwise shadow it).

## Menu / project panels (whichever panel is active).
const PANEL_OFFSET := Vector3(0.0, -0.25, 1.25)
## Project space — the drawing itself.
const PROJECT_OFFSET := Vector3(0.0, -0.5, 0.75)
## Gap between a panel and the virtual keyboard spawned beneath it. A genuine 1-D
## gap along the panel's down-axis, so it stays a scalar.
const KEYBOARD_GAP := 0.025

# --- Haptics ---------------------------------------------------------------
# Controller pulse strength/length for the two feedback flavours, shared by every
# script that buzzes a controller so the whole app feels consistent.
# "Tap" = a single confirming click; "buzz" = a lighter continuous tick.
const HAPTIC_TAP_AMPLITUDE := 0.3
const HAPTIC_TAP_DURATION := 0.05
const HAPTIC_BUZZ_AMPLITUDE := 0.1
const HAPTIC_BUZZ_DURATION := 0.02

# --- MX Ink stylus feel ----------------------------------------------------
# Tuning for the standalone stylus gestures (see interaction.gd for the full
# input model). Grouped here so stylus feel lives beside stylus_joystick_range.
const STYLUS_GATE_ON := 0.05      # tip/side pressure to start a gesture
const STYLUS_GATE_OFF := 0.025    # ...and the lower value to end it (hysteresis)
const STYLUS_WIDTH_SMOOTH := 0.5  # EMA weight on pressure feeding stroke width
const STYLUS_HOLD_DELAY := 0.25   # s a crisp button is held before its hold action starts
const STYLUS_TAP_MAX_MOVE := 0.02 # m — released still (under this) before the delay = a tap
# Value change produced by one full stylus_joystick_range of left/right travel.
const STYLUS_ADJ_AREA_SPAN := 0.15   # active-area radius (m)
const STYLUS_ADJ_SIZE_SPAN := 0.1    # point size (m)
const STYLUS_ADJ_WEIGHT_SPAN := 5.0  # point weight

# --- Misc UX ---------------------------------------------------------------
## Seconds a popup lingers before auto-dismissing (callers may override).
const POPUP_DISMISS_TIME := 30.0
## Default action-area (interaction sphere) radius, in metres, before the user
## or a saved project overrides it.
const ACTION_AREA_DEFAULT_SIZE := 0.1

var export_directory: String = ""
var max_undo_steps: int = 32
var autosave_delay: float = 2.0   # seconds to wait before committing an autosave
var preview_mesh_resolution: int = 8
var preview_spline_resolution: int = 8
# Hand speed (m/s, real-world) that maps to the thinnest stroke in Speed draw
# mode. Slow movement draws thick (full action-area radius); movement at or
# above this speed draws thin. Tuned so a comfortable arm stroke reaches max.
var max_draw_speed: float = 1.5
# Left/right stylus travel (metres) that maps to full deflection of the front-hold
# virtual joystick. Smaller = more sensitive. Used for active-area size and point
# width/weight adjustment when driving those with the MX Ink stylus.
var stylus_joystick_range: float = 0.25


func load_from_file() -> void:
	var fa := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if not fa:
		return  # No settings file yet — use defaults
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	fa.close()
	if not parsed is Dictionary:
		return
	var d: Dictionary = parsed
	# Fallbacks reference the field's own initializer, so each default is defined
	# exactly once (above) and a key missing from settings.json can never drift
	# from the in-code default.
	export_directory = str(d.get("export_directory", export_directory))
	max_undo_steps = clampi(int(d.get("max_undo_steps", max_undo_steps)), 1, 100)
	autosave_delay = clampf(float(d.get("autosave_delay", autosave_delay)), 0.0, 10.0)
	preview_mesh_resolution = clampi(int(d.get("preview_mesh_resolution", preview_mesh_resolution)), 3, 32)
	preview_spline_resolution = clampi(int(d.get("preview_spline_resolution", preview_spline_resolution)), 1, 32)
	max_draw_speed = clampf(float(d.get("max_draw_speed", max_draw_speed)), 0.1, 3.0)
	stylus_joystick_range = clampf(float(d.get("stylus_joystick_range", stylus_joystick_range)), 0.02, 1.0)


func save_to_file() -> void:
	var data := {
		"export_directory": export_directory,
		"max_undo_steps": max_undo_steps,
		"autosave_delay": autosave_delay,
		"preview_mesh_resolution": preview_mesh_resolution,
		"preview_spline_resolution": preview_spline_resolution,
		"max_draw_speed": max_draw_speed,
		"stylus_joystick_range": stylus_joystick_range,
	}
	var fa := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(data, "\t"))
		fa.close()
	else:
		push_error("SettingsData: could not write " + SETTINGS_PATH)
