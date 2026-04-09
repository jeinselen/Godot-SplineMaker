class_name SettingsData
extends RefCounted

## Persistent app settings stored in user://settings.json.

const SETTINGS_PATH := "user://settings.json"

var export_directory: String = ""
var max_undo_steps: int = 32
var autosave_delay: float = 2.0   # seconds to wait before committing an autosave
var panel_side: String = "left"   # "left" or "right"
var preview_mesh_resolution: int = 8
var preview_spline_resolution: int = 8


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
	var side: String = str(d.get("panel_side", "left"))
	panel_side = side if side in ["left", "right"] else "left"
	preview_mesh_resolution = clampi(int(d.get("preview_mesh_resolution", 8)), 3, 32)
	preview_spline_resolution = clampi(int(d.get("preview_spline_resolution", 8)), 1, 32)


func save_to_file() -> void:
	var data := {
		"export_directory": export_directory,
		"max_undo_steps": max_undo_steps,
		"autosave_delay": autosave_delay,
		"panel_side": panel_side,
		"preview_mesh_resolution": preview_mesh_resolution,
		"preview_spline_resolution": preview_spline_resolution,
	}
	var fa := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(data, "\t"))
		fa.close()
	else:
		push_error("SettingsData: could not write " + SETTINGS_PATH)
