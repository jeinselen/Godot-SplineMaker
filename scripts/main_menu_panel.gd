class_name MainMenuPanel
extends XRPanel

## Main menu panel: project list with rename/delete, new project button,
## and settings sub-panel. Displayed on app launch before entering a project.

var _app_manager = null
var _project_manager = null

# UI references
var _main_vbox: VBoxContainer
var _project_list_container: VBoxContainer
var _project_scroll: ScrollContainer
var _settings_view: VBoxContainer
var _import_view: VBoxContainer
var _import_list_container: VBoxContainer
var _import_path_label: Label

# Settings controls
var _export_path_edit: LineEdit
var _undo_steps_spin: SpinBox
var _autosave_delay_spin: SpinBox
var _panel_side_btn: Button
var _mesh_res_spin: SpinBox
var _spline_res_spin: SpinBox

# Delete confirmation state
var _delete_confirm_dir: String = ""
var _delete_confirm_row: HBoxContainer = null

# Rename state
var _rename_edit: LineEdit = null
var _rename_dir: String = ""

# Which overlay view is showing (null = main list, otherwise _settings_view or _import_view)
var _active_overlay: VBoxContainer = null

const PANEL_UI_SCENE := preload("res://scenes/ui/main_menu_panel_ui.tscn")


static func create_panel(app_mgr) -> MainMenuPanel:
	var panel := MainMenuPanel.new()
	panel.panel_size = Vector2(512, 640)
	panel._app_manager = app_mgr
	return panel


func _ready() -> void:
	super._ready()

	_project_manager = _app_manager.project_manager
	_build_ui()
	_refresh_project_list()


## Position centered in front of the camera (overrides side offset).
func reset_position(camera: XRCamera3D, _side: String = "center") -> void:
	var cam_t := camera.global_transform

	# Use world-aligned horizontal forward (ignore head pitch/roll)
	var cam_forward := -cam_t.basis.z
	var horizontal_forward := Vector3(cam_forward.x, 0.0, cam_forward.z).normalized()

	var target_pos := cam_t.origin + horizontal_forward * 0.9 + Vector3.UP * 0.1
	var away_target := target_pos + horizontal_forward

	global_transform = Transform3D.IDENTITY
	global_position = target_pos
	look_at(away_target, Vector3.UP)


func _build_ui() -> void:
	var ui := PANEL_UI_SCENE.instantiate() as Control
	content_root.add_child(ui)

	_main_vbox = ui.find_child("MainVBox", true, false) as VBoxContainer
	_project_scroll = ui.find_child("ProjectScroll", true, false) as ScrollContainer
	_project_list_container = ui.find_child("ProjectList", true, false) as VBoxContainer

	var new_btn := ui.find_child("NewProjectButton", true, false) as Button
	new_btn.pressed.connect(_on_new_project_pressed)

	var import_btn := ui.find_child("ImportProjectButton", true, false) as Button
	import_btn.pressed.connect(_on_import_pressed)

	var settings_btn := ui.find_child("SettingsButton", true, false) as Button
	settings_btn.pressed.connect(_on_settings_pressed)

	var quit_btn := ui.find_child("QuitButton", true, false) as Button
	quit_btn.pressed.connect(_on_quit_pressed)

	_settings_view = ui.find_child("SettingsView", true, false) as VBoxContainer
	_export_path_edit = ui.find_child("ExportPathEdit", true, false) as LineEdit
	_export_path_edit.text = _app_manager.settings.export_directory
	_export_path_edit.text_submitted.connect(_on_export_path_submitted)
	_export_path_edit.focus_entered.connect(_on_export_path_focus_entered)
	_export_path_edit.focus_exited.connect(_on_input_focus_exited)

	var edit_btn := ui.find_child("ExportPathEditButton", true, false) as Button
	edit_btn.pressed.connect(_on_export_path_edit_pressed)

	_undo_steps_spin = ui.find_child("UndoStepsSpin", true, false) as SpinBox
	_undo_steps_spin.value = _app_manager.settings.max_undo_steps
	_wire_spinbox_keyboard(_undo_steps_spin)

	_autosave_delay_spin = ui.find_child("AutosaveDelaySpin", true, false) as SpinBox
	_autosave_delay_spin.value = _app_manager.settings.autosave_delay
	_wire_spinbox_keyboard(_autosave_delay_spin)

	_panel_side_btn = ui.find_child("PanelSideButton", true, false) as Button
	_panel_side_btn.text = _app_manager.settings.panel_side.capitalize()
	_panel_side_btn.pressed.connect(_on_panel_side_toggled)

	_mesh_res_spin = ui.find_child("MeshResolutionSpin", true, false) as SpinBox
	_mesh_res_spin.value = _app_manager.settings.preview_mesh_resolution
	_wire_spinbox_keyboard(_mesh_res_spin)

	_spline_res_spin = ui.find_child("SplineResolutionSpin", true, false) as SpinBox
	_spline_res_spin.value = _app_manager.settings.preview_spline_resolution
	_wire_spinbox_keyboard(_spline_res_spin)

	var back_btn := ui.find_child("SettingsBackButton", true, false) as Button
	back_btn.pressed.connect(_on_settings_back_pressed)

	_import_view = ui.find_child("ImportView", true, false) as VBoxContainer
	_import_path_label = ui.find_child("ImportPathLabel", true, false) as Label
	_import_list_container = ui.find_child("ImportList", true, false) as VBoxContainer

	var refresh_btn := ui.find_child("ImportRefreshButton", true, false) as Button
	refresh_btn.pressed.connect(_refresh_import_list)

	var import_back_btn := ui.find_child("ImportBackButton", true, false) as Button
	import_back_btn.pressed.connect(_show_main_view)


# --- Overlay view helpers ---

## Show the main project list, hiding any overlay.
func _show_main_view() -> void:
	if _active_overlay:
		_active_overlay.visible = false
		_active_overlay = null
	for child in _main_vbox.get_children():
		if child != _settings_view and child != _import_view:
			child.visible = true
	_refresh_project_list()


## Hide main content and show the given overlay view.
func _show_overlay(view: VBoxContainer) -> void:
	for child in _main_vbox.get_children():
		if child != _settings_view and child != _import_view:
			child.visible = false
	if _active_overlay and _active_overlay != view:
		_active_overlay.visible = false
	_active_overlay = view
	view.visible = true


# --- Project list ---

func _refresh_project_list() -> void:
	# Clear existing rows
	for child in _project_list_container.get_children():
		child.queue_free()

	var dirs: Array = _project_manager.list_project_dirs()

	if dirs.is_empty():
		var empty := Label.new()
		empty.text = "No projects yet"
		empty.add_theme_font_size_override("font_size", 18)
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_project_list_container.add_child(empty)
		return

	# Show newest first
	dirs.reverse()
	for dir_name in dirs:
		var display_name: String = _project_manager.get_project_name(dir_name)
		var row := _create_project_row(dir_name, display_name)
		_project_list_container.add_child(row)


func _create_project_row(dir_name: String, display_name: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)

	var open_btn := Button.new()
	open_btn.text = display_name
	open_btn.add_theme_font_size_override("font_size", 18)
	open_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_btn.pressed.connect(_on_project_open_pressed.bind(dir_name))
	row.add_child(open_btn)

	var rename_btn := Button.new()
	rename_btn.text = "Rename"
	rename_btn.add_theme_font_size_override("font_size", 16)
	rename_btn.pressed.connect(_on_project_rename_pressed.bind(dir_name, row))
	row.add_child(rename_btn)

	var del_btn := Button.new()
	del_btn.text = "Delete"
	del_btn.add_theme_font_size_override("font_size", 16)
	del_btn.pressed.connect(_on_project_delete_pressed.bind(dir_name, row))
	row.add_child(del_btn)

	return row


# --- Project actions ---

func _on_project_open_pressed(dir_name: String) -> void:
	_app_manager.open_project(dir_name)


func _on_new_project_pressed() -> void:
	_app_manager.create_and_open_project()


func _on_quit_pressed() -> void:
	get_tree().quit()


# --- Rename ---

func _on_project_rename_pressed(dir_name: String, row: HBoxContainer) -> void:
	# Replace the row content with a LineEdit for typing the new name
	_rename_dir = dir_name

	# Hide existing children
	for child in row.get_children():
		child.visible = false

	_rename_edit = LineEdit.new()
	_rename_edit.text = _project_manager.get_project_name(dir_name)
	_rename_edit.add_theme_font_size_override("font_size", 18)
	_rename_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rename_edit.text_submitted.connect(_on_rename_submitted.bind(dir_name))
	row.add_child(_rename_edit)
	_rename_edit.grab_focus()

	var kb: XRKeyboard = _app_manager.request_keyboard(_rename_edit, "qwerty", self)
	if kb:
		kb.cancelled.connect(_refresh_project_list)


func _on_rename_submitted(new_name: String, dir_name: String) -> void:
	_app_manager.dismiss_keyboard()
	if not new_name.is_empty() and new_name != dir_name:
		_project_manager.rename_project(dir_name, new_name)
	_refresh_project_list()


# --- Delete ---

func _on_project_delete_pressed(dir_name: String, row: HBoxContainer) -> void:
	# Replace row with confirmation
	_delete_confirm_dir = dir_name
	_delete_confirm_row = row

	for child in row.get_children():
		child.visible = false

	var confirm_label := Label.new()
	confirm_label.text = "Delete?"
	confirm_label.add_theme_font_size_override("font_size", 18)
	confirm_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	confirm_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(confirm_label)

	var yes_btn := Button.new()
	yes_btn.text = "Yes"
	yes_btn.add_theme_font_size_override("font_size", 16)
	yes_btn.pressed.connect(_on_delete_confirmed.bind(dir_name))
	row.add_child(yes_btn)

	var no_btn := Button.new()
	no_btn.text = "No"
	no_btn.add_theme_font_size_override("font_size", 16)
	no_btn.pressed.connect(func() -> void: _refresh_project_list())
	row.add_child(no_btn)


func _on_delete_confirmed(dir_name: String) -> void:
	_project_manager.delete_project(dir_name)
	_delete_confirm_dir = ""
	_delete_confirm_row = null
	_refresh_project_list()


# --- Settings ---

func _on_settings_pressed() -> void:
	_show_overlay(_settings_view)


func _on_settings_back_pressed() -> void:
	# Save settings before returning
	_app_manager.settings.export_directory = _export_path_edit.text
	_app_manager.settings.max_undo_steps = int(_undo_steps_spin.value)
	_app_manager.settings.autosave_delay = _autosave_delay_spin.value
	_app_manager.settings.panel_side = "left" if _panel_side_btn.text == "Left" else "right"
	_app_manager.settings.preview_mesh_resolution = int(_mesh_res_spin.value)
	_app_manager.settings.preview_spline_resolution = int(_spline_res_spin.value)
	_app_manager.apply_settings()
	_show_main_view()


func _on_panel_side_toggled() -> void:
	if _panel_side_btn.text == "Left":
		_panel_side_btn.text = "Right"
	else:
		_panel_side_btn.text = "Left"


func _on_import_pressed() -> void:
	_show_overlay(_import_view)
	_refresh_import_list()


func _refresh_import_list() -> void:
	for child in _import_list_container.get_children():
		child.free()

	var export_dir: String = _project_manager.get_export_dir()
	print("Import: scanning directory: ", export_dir)
	_import_path_label.text = export_dir

	var da := DirAccess.open(export_dir)
	if not da:
		print("Import: DirAccess.open() failed for: ", export_dir)
		var empty := Label.new()
		empty.text = "Folder not found:\n" + export_dir
		empty.add_theme_font_size_override("font_size", 16)
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_import_list_container.add_child(empty)
		return

	var files: Array[String] = []
	da.list_dir_begin()
	var entry := da.get_next()
	while entry != "":
		if not da.current_is_dir() and entry.ends_with(".json"):
			files.append(entry)
		entry = da.get_next()
	da.list_dir_end()
	files.sort()
	print("Import: found ", files.size(), " .json file(s): ", files)

	if files.is_empty():
		var empty := Label.new()
		empty.text = "No .json files found"
		empty.add_theme_font_size_override("font_size", 18)
		empty.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_import_list_container.add_child(empty)
		return

	for file_name in files:
		var full_path: String = export_dir + file_name
		var btn := Button.new()
		btn.text = file_name.trim_suffix(".json")
		btn.add_theme_font_size_override("font_size", 18)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_import_file_pressed.bind(full_path))
		_import_list_container.add_child(btn)


func _on_import_file_pressed(json_path: String) -> void:
	_app_manager.import_and_open_project(json_path)


func _on_export_path_edit_pressed() -> void:
	_export_path_edit.grab_focus()
	_app_manager.request_keyboard(_export_path_edit, "qwerty", self)


func _on_export_path_submitted(new_text: String) -> void:
	_app_manager.dismiss_keyboard()
	_export_path_edit.text = new_text


func _on_export_path_focus_entered() -> void:
	_app_manager.request_keyboard(_export_path_edit, "qwerty", self)


## Wire a SpinBox's internal LineEdit so a direct click on the text area spawns
## the numpad. Using gui_input rather than focus_entered means the up/down
## arrow buttons (which focus the LineEdit as a side effect) don't trigger it.
func _wire_spinbox_keyboard(spin: SpinBox) -> void:
	var le := spin.get_line_edit()
	le.gui_input.connect(_on_spin_le_gui_input.bind(spin))
	le.focus_exited.connect(_on_input_focus_exited)


func _on_spin_le_gui_input(event: InputEvent, spin: SpinBox) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_app_manager.request_keyboard(spin, "numpad", self)


## Dismiss the keyboard one frame later if no other input grabbed focus
## (which would have already replaced the keyboard via request_keyboard).
func _on_input_focus_exited() -> void:
	await get_tree().process_frame
	if not _app_manager:
		return
	var kb: XRKeyboard = _app_manager._active_keyboard
	if not kb or not is_instance_valid(kb):
		return
	var target_le: LineEdit = null
	if kb.target_control is LineEdit:
		target_le = kb.target_control as LineEdit
	elif kb.target_control is SpinBox:
		target_le = (kb.target_control as SpinBox).get_line_edit()
	if target_le and not target_le.has_focus():
		_app_manager.dismiss_keyboard()
