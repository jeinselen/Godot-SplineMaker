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

# Settings controls
var _export_path_edit: LineEdit
var _undo_steps_spin: SpinBox
var _autosave_delay_spin: SpinBox
var _panel_side_btn: Button
var _mesh_res_spin: SpinBox

# Delete confirmation state
var _delete_confirm_dir: String = ""
var _delete_confirm_row: HBoxContainer = null

# Rename state
var _rename_edit: LineEdit = null
var _rename_dir: String = ""

# Which view is showing
var _showing_settings: bool = false


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
	var panel_container := PanelContainer.new()
	panel_container.set_anchors_preset(Control.PRESET_FULL_RECT)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.85)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	panel_container.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel_container.add_child(margin)

	_main_vbox = VBoxContainer.new()
	_main_vbox.add_theme_constant_override("separation", 8)
	margin.add_child(_main_vbox)

	# --- Title ---
	var title := Label.new()
	title.text = "SplineMaker"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_main_vbox.add_child(title)

	_main_vbox.add_child(HSeparator.new())

	# --- Project list (scrollable) ---
	_project_scroll = ScrollContainer.new()
	_project_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_project_scroll.custom_minimum_size = Vector2(0, 300)
	_main_vbox.add_child(_project_scroll)

	_project_list_container = VBoxContainer.new()
	_project_list_container.add_theme_constant_override("separation", 4)
	_project_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_project_scroll.add_child(_project_list_container)

	_main_vbox.add_child(HSeparator.new())

	# --- Bottom buttons ---
	var new_btn := Button.new()
	new_btn.text = "New Project"
	new_btn.add_theme_font_size_override("font_size", 20)
	new_btn.pressed.connect(_on_new_project_pressed)
	_main_vbox.add_child(new_btn)

	var settings_btn := Button.new()
	settings_btn.text = "Settings"
	settings_btn.add_theme_font_size_override("font_size", 20)
	settings_btn.pressed.connect(_on_settings_pressed)
	_main_vbox.add_child(settings_btn)

	var quit_btn := Button.new()
	quit_btn.text = "Quit"
	quit_btn.add_theme_font_size_override("font_size", 20)
	quit_btn.pressed.connect(_on_quit_pressed)
	_main_vbox.add_child(quit_btn)

	# --- Settings view (hidden by default) ---
	_build_settings_view()

	content_root.add_child(panel_container)


func _build_settings_view() -> void:
	_settings_view = VBoxContainer.new()
	_settings_view.add_theme_constant_override("separation", 8)
	_settings_view.visible = false
	_main_vbox.add_child(_settings_view)

	var settings_title := Label.new()
	settings_title.text = "Settings"
	settings_title.add_theme_font_size_override("font_size", 24)
	settings_title.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))
	settings_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_settings_view.add_child(settings_title)

	_settings_view.add_child(HSeparator.new())

	# Export Path
	var export_row := HBoxContainer.new()
	export_row.add_theme_constant_override("separation", 6)
	_settings_view.add_child(export_row)
	var export_label := Label.new()
	export_label.text = "Export Path"
	export_label.add_theme_font_size_override("font_size", 18)
	export_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	export_row.add_child(export_label)
	_export_path_edit = LineEdit.new()
	_export_path_edit.placeholder_text = "Documents/Splines/"
	_export_path_edit.add_theme_font_size_override("font_size", 16)
	_export_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_export_path_edit.text = _app_manager.settings.export_directory
	_export_path_edit.text_submitted.connect(_on_export_path_submitted)
	export_row.add_child(_export_path_edit)
	var edit_btn := Button.new()
	edit_btn.text = "Edit"
	edit_btn.add_theme_font_size_override("font_size", 16)
	edit_btn.pressed.connect(_on_export_path_edit_pressed)
	export_row.add_child(edit_btn)

	# Undo Steps
	var undo_row := HBoxContainer.new()
	undo_row.add_theme_constant_override("separation", 6)
	_settings_view.add_child(undo_row)
	var undo_label := Label.new()
	undo_label.text = "Undo Steps"
	undo_label.add_theme_font_size_override("font_size", 18)
	undo_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	undo_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	undo_row.add_child(undo_label)
	_undo_steps_spin = SpinBox.new()
	_undo_steps_spin.min_value = 1
	_undo_steps_spin.max_value = 100
	_undo_steps_spin.value = _app_manager.settings.max_undo_steps
	_undo_steps_spin.add_theme_font_size_override("font_size", 18)
	undo_row.add_child(_undo_steps_spin)

	# Autosave Delay
	var delay_row := HBoxContainer.new()
	delay_row.add_theme_constant_override("separation", 6)
	_settings_view.add_child(delay_row)
	var delay_label := Label.new()
	delay_label.text = "Autosave Delay"
	delay_label.add_theme_font_size_override("font_size", 18)
	delay_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	delay_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	delay_row.add_child(delay_label)
	_autosave_delay_spin = SpinBox.new()
	_autosave_delay_spin.min_value = 0.0
	_autosave_delay_spin.max_value = 10.0
	_autosave_delay_spin.step = 0.5
	_autosave_delay_spin.value = _app_manager.settings.autosave_delay
	_autosave_delay_spin.suffix = "s"
	_autosave_delay_spin.add_theme_font_size_override("font_size", 18)
	delay_row.add_child(_autosave_delay_spin)

	# Panel Side
	var side_row := HBoxContainer.new()
	side_row.add_theme_constant_override("separation", 6)
	_settings_view.add_child(side_row)
	var side_label := Label.new()
	side_label.text = "Panel Side"
	side_label.add_theme_font_size_override("font_size", 18)
	side_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	side_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side_row.add_child(side_label)
	_panel_side_btn = Button.new()
	_panel_side_btn.text = _app_manager.settings.panel_side.capitalize()
	_panel_side_btn.add_theme_font_size_override("font_size", 18)
	_panel_side_btn.pressed.connect(_on_panel_side_toggled)
	side_row.add_child(_panel_side_btn)

	# Mesh Resolution
	var mesh_row := HBoxContainer.new()
	mesh_row.add_theme_constant_override("separation", 6)
	_settings_view.add_child(mesh_row)
	var mesh_label := Label.new()
	mesh_label.text = "Mesh Resolution"
	mesh_label.add_theme_font_size_override("font_size", 18)
	mesh_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	mesh_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mesh_row.add_child(mesh_label)
	_mesh_res_spin = SpinBox.new()
	_mesh_res_spin.min_value = 3
	_mesh_res_spin.max_value = 32
	_mesh_res_spin.value = _app_manager.settings.preview_mesh_resolution
	_mesh_res_spin.add_theme_font_size_override("font_size", 18)
	mesh_row.add_child(_mesh_res_spin)

	# Back button
	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.add_theme_font_size_override("font_size", 20)
	back_btn.pressed.connect(_on_settings_back_pressed)
	_settings_view.add_child(back_btn)


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

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.add_theme_font_size_override("font_size", 16)
	cancel_btn.pressed.connect(func() -> void: _refresh_project_list())
	row.add_child(cancel_btn)

	# Open virtual keyboard on Android/Quest 3 (deferred to let focus settle)
	_show_virtual_keyboard(_rename_edit.text)


func _on_rename_submitted(new_name: String, dir_name: String) -> void:
	DisplayServer.virtual_keyboard_hide()
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
	_showing_settings = true
	# Hide main content, show settings
	for child in _main_vbox.get_children():
		if child != _settings_view:
			child.visible = false
	_settings_view.visible = true


func _on_settings_back_pressed() -> void:
	# Save settings
	_app_manager.settings.export_directory = _export_path_edit.text
	_app_manager.settings.max_undo_steps = int(_undo_steps_spin.value)
	_app_manager.settings.autosave_delay = _autosave_delay_spin.value
	_app_manager.settings.panel_side = "left" if _panel_side_btn.text == "Left" else "right"
	_app_manager.settings.preview_mesh_resolution = int(_mesh_res_spin.value)
	_app_manager.apply_settings()

	# Show main content, hide settings
	_showing_settings = false
	_settings_view.visible = false
	for child in _main_vbox.get_children():
		if child != _settings_view:
			child.visible = true
	_refresh_project_list()


func _on_panel_side_toggled() -> void:
	if _panel_side_btn.text == "Left":
		_panel_side_btn.text = "Right"
	else:
		_panel_side_btn.text = "Left"


func _on_export_path_edit_pressed() -> void:
	_export_path_edit.grab_focus()
	_show_virtual_keyboard(_export_path_edit.text)


func _on_export_path_submitted(new_text: String) -> void:
	DisplayServer.virtual_keyboard_hide()
	_export_path_edit.text = new_text


## Show virtual keyboard after a frame delay so LineEdit focus settles first.
func _show_virtual_keyboard(text: String) -> void:
	await get_tree().process_frame
	DisplayServer.virtual_keyboard_show(text)
