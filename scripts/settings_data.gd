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
const PANEL_OFFSET := Vector3(0.0, -0.25, 2.0)
## Project space — the drawing itself.
const PROJECT_OFFSET := Vector3(0.0, -0.5, 1.0)
## Gap between a panel and the virtual keyboard spawned beneath it. A genuine 1-D
## gap along the panel's down-axis, so it stays a scalar.
const KEYBOARD_GAP := 0.025

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
	export_directory = str(d.get("export_directory", ""))
	max_undo_steps = clampi(int(d.get("max_undo_steps", 32)), 1, 100)
	autosave_delay = clampf(float(d.get("autosave_delay", 2.0)), 0.0, 10.0)
	preview_mesh_resolution = clampi(int(d.get("preview_mesh_resolution", 8)), 3, 32)
	preview_spline_resolution = clampi(int(d.get("preview_spline_resolution", 8)), 1, 32)
	max_draw_speed = clampf(float(d.get("max_draw_speed", 1.2)), 0.1, 3.0)
	stylus_joystick_range = clampf(float(d.get("stylus_joystick_range", 0.15)), 0.02, 1.0)


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
