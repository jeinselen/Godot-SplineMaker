extends Node

## Manages project persistence: JSON-based save files, auto-save on edit commit,
## and file-based undo/redo. On startup, opens the most recent project or creates
## a new one. Each autosave writes an incrementally-numbered JSON file.

@onready var project_space: Node3D = %ProjectSpace
@onready var interaction = %Interaction  # untyped to avoid circular class dependency

const PROJECTS_ROOT := "user://projects/"
const META_FILE := "meta.json"
const SAVE_PREFIX := "save_"
const SAVE_EXT := ".json"
const EXPORT_FILE := "splines.json"
const JSON_VERSION := 1

@export var max_undo_steps: int = 32
## Directory where exported JSON files are written on project close.
## Defaults to user://exports/ on Quest 3; overridden by settings.
@export var export_directory: String = ""

signal export_succeeded(path: String)
signal export_failed(error: String)
signal project_opened
signal project_closed

var _project_dir: String = ""
var _save_counter: int = 0        # total saves ever written; monotonically increases
var _undo_stack: Array[int] = []  # ordered list of save file numbers present on disk
var _undo_index: int = -1         # index into _undo_stack of the currently loaded state
var _is_restoring: bool = false   # suppresses autosave during undo/redo restore


func _ready() -> void:
	export_failed.connect(_on_export_failed)
	export_succeeded.connect(_on_export_succeeded)


# --- Project open / create ---

## Lists all project directory names sorted alphabetically.
func list_project_dirs() -> Array[String]:
	DirAccess.make_dir_recursive_absolute(PROJECTS_ROOT)
	var da := DirAccess.open(PROJECTS_ROOT)
	if not da:
		return []
	var result: Array[String] = []
	da.list_dir_begin()
	var entry := da.get_next()
	while entry != "":
		if da.current_is_dir() and not entry.begins_with("."):
			result.append(entry)
		entry = da.get_next()
	da.list_dir_end()
	result.sort()
	return result


## Creates a new timestamped project. Returns the directory name.
func create_new_project() -> String:
	var raw := Time.get_datetime_string_from_system(false, true)
	var timestamp := raw.replace("T", "-").replace(":", "-").left(16)
	_project_dir = PROJECTS_ROOT + timestamp + "/"
	DirAccess.make_dir_recursive_absolute(_project_dir)
	_save_counter = 0
	_undo_stack = []
	_undo_index = -1
	_write_meta()
	autosave()  # write initial empty-state save so undo can return to blank canvas
	project_opened.emit()
	return timestamp


## Opens an existing project by directory name.
func open_project(dir_name: String) -> void:
	_project_dir = PROJECTS_ROOT + dir_name + "/"
	_read_meta()
	_undo_stack = _scan_save_files()
	if _undo_stack.is_empty():
		_save_counter = 0
		_undo_index = -1
		autosave()
	else:
		_undo_index = _undo_stack.size() - 1
		_load_save_file(_undo_stack[_undo_index])
	project_opened.emit()


## Deletes a project folder and all its contents.
func delete_project(dir_name: String) -> void:
	var dir_path := PROJECTS_ROOT + dir_name + "/"
	var da := DirAccess.open(dir_path)
	if not da:
		push_error("ProjectManager: could not open " + dir_path + " for deletion")
		return
	# Delete all files in the project directory
	da.list_dir_begin()
	var entry := da.get_next()
	while entry != "":
		if not da.current_is_dir():
			DirAccess.remove_absolute(dir_path + entry)
		entry = da.get_next()
	da.list_dir_end()
	# Remove the directory itself
	DirAccess.remove_absolute(dir_path)


## Renames a project. Updates the directory name and meta.json.
func rename_project(dir_name: String, new_name: String) -> void:
	var old_path := PROJECTS_ROOT + dir_name
	var new_path := PROJECTS_ROOT + new_name
	var err := DirAccess.rename_absolute(old_path, new_path)
	if err != OK:
		push_error("ProjectManager: rename failed from %s to %s (error %d)" % [old_path, new_path, err])
		return
	# Update meta.json with the new name
	var meta_path := new_path + "/" + META_FILE
	var fa := FileAccess.open(meta_path, FileAccess.READ)
	if fa:
		var parsed: Variant = JSON.parse_string(fa.get_as_text())
		fa.close()
		if parsed is Dictionary:
			parsed["name"] = new_name
			var fw := FileAccess.open(meta_path, FileAccess.WRITE)
			if fw:
				fw.store_string(JSON.stringify(parsed, "\t"))
				fw.close()


## Returns the display name for a project directory.
func get_project_name(dir_name: String) -> String:
	var meta_path := PROJECTS_ROOT + dir_name + "/" + META_FILE
	var fa := FileAccess.open(meta_path, FileAccess.READ)
	if fa:
		var parsed: Variant = JSON.parse_string(fa.get_as_text())
		fa.close()
		if parsed is Dictionary:
			return str(parsed.get("name", dir_name))
	return dir_name


func _scan_save_files() -> Array[int]:
	var da := DirAccess.open(_project_dir)
	if not da:
		return []
	var nums: Array[int] = []
	da.list_dir_begin()
	var entry := da.get_next()
	while entry != "":
		if entry.begins_with(SAVE_PREFIX) and entry.ends_with(SAVE_EXT):
			var num_str := entry.trim_prefix(SAVE_PREFIX).trim_suffix(SAVE_EXT)
			if num_str.is_valid_int():
				nums.append(num_str.to_int())
		entry = da.get_next()
	da.list_dir_end()
	nums.sort()
	return nums


# --- Meta file ---

func _write_meta() -> void:
	var data := {
		"name": _project_dir.get_base_dir().get_file(),
		"save_counter": _save_counter
	}
	var path := _project_dir + META_FILE
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(data, "\t"))
		fa.close()
	else:
		push_error("ProjectManager: could not write meta.json to " + path)


func _read_meta() -> void:
	var path := _project_dir + META_FILE
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		_save_counter = 0
		return
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	fa.close()
	if parsed is Dictionary:
		_save_counter = int(parsed.get("save_counter", 0))
	else:
		_save_counter = 0


# --- Auto-save ---

## Called by interaction.gd after every committed edit.
func autosave() -> void:
	if _is_restoring:
		return
	_truncate_redo_history()
	_save_counter += 1
	_write_save_file(_save_counter)
	_undo_stack.append(_save_counter)
	_undo_index = _undo_stack.size() - 1
	_enforce_undo_limit()
	_write_meta()


func _truncate_redo_history() -> void:
	if _undo_index < _undo_stack.size() - 1:
		for i in range(_undo_index + 1, _undo_stack.size()):
			DirAccess.remove_absolute(_project_dir + _save_filename(_undo_stack[i]))
		_undo_stack.resize(_undo_index + 1)


func _enforce_undo_limit() -> void:
	while _undo_stack.size() > max_undo_steps:
		DirAccess.remove_absolute(_project_dir + _save_filename(_undo_stack[0]))
		_undo_stack.remove_at(0)
		_undo_index = maxi(_undo_index - 1, 0)


# --- Undo / Redo ---

func can_undo() -> bool:
	return _undo_index > 0


func can_redo() -> bool:
	return _undo_index < _undo_stack.size() - 1


func undo() -> void:
	if not can_undo():
		return
	_undo_index -= 1
	_load_save_file(_undo_stack[_undo_index])


func redo() -> void:
	if not can_redo():
		return
	_undo_index += 1
	_load_save_file(_undo_stack[_undo_index])


# --- Serialization ---

func _serialize_state() -> Dictionary:
	var splines_data: Array = []
	for child in project_space.get_children():
		if child is SplineNode:
			var sn := child as SplineNode
			if not sn.data or not sn.is_active:
				continue  # skip in-progress or cancelled DrawPreview nodes
			var pts: Array = []
			for i in sn.data.point_count():
				pts.append({
					"x": sn.data.points[i].x,
					"y": sn.data.points[i].y,
					"z": sn.data.points[i].z,
					"size": sn.data.sizes[i],
					"weight": sn.data.weights[i],
				})
			splines_data.append({
				"order_u": sn.data.order_u,
				"resolution_u": sn.data.resolution_u,
				"cyclic": sn.data.cyclic,
				"points": pts,
			})
	return {
		"version": JSON_VERSION,
		"splines": splines_data,
		"action_area_sizes": {
			"left": interaction.left_action_area.radius,
			"right": interaction.right_action_area.radius,
		}
	}


func _restore_state(state: Dictionary) -> void:
	_is_restoring = true

	# Clear stale hover state before freeing nodes to avoid dangling references
	interaction.clear_hover_sets()

	# Free existing SplineNodes immediately (not queue_free) so get_children()
	# returns the updated list on the same frame
	for child in project_space.get_children():
		if child is SplineNode:
			child.free()

	# Rebuild SplineNodes from saved data
	for spline_dict in state.get("splines", []):
		var sd := SplineData.new()
		sd.order_u = int(spline_dict.get("order_u", 4))
		sd.resolution_u = int(spline_dict.get("resolution_u", 8))
		sd.cyclic = bool(spline_dict.get("cyclic", false))
		for pt in spline_dict.get("points", []):
			sd.add_point(
				Vector3(float(pt.get("x", 0.0)), float(pt.get("y", 0.0)), float(pt.get("z", 0.0))),
				float(pt.get("size", 0.1)),
				float(pt.get("weight", 1.0))
			)
		var sn := SplineNode.new()
		sn.name = "Spline"
		sn.data = sd
		project_space.add_child(sn)
		sn.set_active(true)
		sn.mark_dirty()

	# Restore action area sizes
	var aa: Dictionary = state.get("action_area_sizes", {})
	interaction.restore_action_area_sizes(
		float(aa.get("left", ActionArea.SIZE_DEFAULT)),
		float(aa.get("right", ActionArea.SIZE_DEFAULT))
	)

	_is_restoring = false


# --- File I/O helpers ---

func _save_filename(file_num: int) -> String:
	return SAVE_PREFIX + "%03d" % file_num + SAVE_EXT


func _write_save_file(file_num: int) -> void:
	var path := _project_dir + _save_filename(file_num)
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa:
		fa.store_string(JSON.stringify(_serialize_state(), "\t"))
		fa.close()
	else:
		push_error("ProjectManager: could not write " + path)


func _load_save_file(file_num: int) -> void:
	var path := _project_dir + _save_filename(file_num)
	var fa := FileAccess.open(path, FileAccess.READ)
	if not fa:
		push_error("ProjectManager: could not read " + path)
		return
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	fa.close()
	if not parsed is Dictionary:
		push_error("ProjectManager: JSON parse failed for " + path)
		return
	_restore_state(parsed)


# --- Project close & JSON export ---

## Returns the resolved export directory, creating it if needed.
func _get_export_dir() -> String:
	var dir := export_directory
	if dir.is_empty():
		# Default: Documents/Splines/ — on Quest 3 this resolves to shared storage.
		# Fall back to user://exports/ if OS path unavailable.
		var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
		if docs.is_empty():
			dir = "user://exports/"
		else:
			dir = docs.path_join("Splines")
	# Ensure trailing slash
	if not dir.ends_with("/"):
		dir += "/"
	return dir


## Closes the current project: exports a clean JSON file to the export directory,
## clears project space, and emits project_closed.
## Returns true on successful export, false on failure.
func close_project() -> bool:
	var success := export_json()
	# Clear hover state before freeing nodes
	interaction.clear_hover_sets()
	# Free all SplineNodes from the project space
	for child in project_space.get_children():
		if child is SplineNode:
			child.free()
	_project_dir = ""
	_save_counter = 0
	_undo_stack = []
	_undo_index = -1
	project_closed.emit()
	return success


## Writes the current spline state as a clean JSON file to the export directory.
## The file is named after the project (e.g. "2026-04-08-14-30.json").
## Returns true on success.
func export_json() -> bool:
	var export_dir := _get_export_dir()

	# Create the export directory
	var err := DirAccess.make_dir_recursive_absolute(export_dir)
	if err != OK and err != ERR_ALREADY_EXISTS:
		var msg := "Could not create export directory: %s (error %d)" % [export_dir, err]
		push_error("ProjectManager: " + msg)
		export_failed.emit(msg)
		return false

	# Build export filename from the project folder name
	var project_name: String = _project_dir.get_base_dir().get_file()
	if project_name.is_empty():
		project_name = "export"
	var export_path := export_dir + project_name + ".json"

	# Serialize current state (same format used by autosave)
	var state := _serialize_state()

	# Write the file
	var fa := FileAccess.open(export_path, FileAccess.WRITE)
	if not fa:
		var msg := "Could not write export file: %s" % export_path
		push_error("ProjectManager: " + msg)
		export_failed.emit(msg)
		return false

	fa.store_string(JSON.stringify(state, "\t"))
	fa.close()

	print("ProjectManager: exported JSON to " + export_path)
	export_succeeded.emit(export_path)
	return true


# --- Export popups ---

func _on_export_succeeded(path: String) -> void:
	var am = get_node_or_null("%AppManager")
	if am:
		am.show_popup("Export saved:\n" + path.get_file(), Color(0.3, 1.0, 0.5))


func _on_export_failed(error: String) -> void:
	var am = get_node_or_null("%AppManager")
	if am:
		am.show_popup("Export failed:\n" + error, Color(1.0, 0.3, 0.3))
