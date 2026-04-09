class_name InProjectPanel
extends XRPanel

## In-project control panel: mode selection, undo/redo, spline list, and
## selected spline properties. Built entirely in code using Godot Control nodes
## inside the XRPanel's SubViewport.

var _app_manager = null  # AppManager reference
var _project_manager = null
var _interaction = null
var _project_space: Node3D = null
var _navigation = null

# UI references
var _undo_btn: Button
var _redo_btn: Button
var _mode_buttons: Array[Button] = []
var _mode_group: ButtonGroup
var _accuracy_slider: HSlider
var _accuracy_container: HBoxContainer
var _spline_list_container: VBoxContainer
var _spline_scroll: ScrollContainer
var _empty_label: Label
var _props_container: VBoxContainer
var _order_spin: SpinBox
var _resolution_spin: SpinBox
var _cyclic_check: CheckButton

# Track spline list items for efficient updates
var _spline_rows: Array[Dictionary] = []  # [{node: HBoxContainer, spline: SplineNode}]

# Suppress property change signals during programmatic updates
var _updating_props: bool = false


static func create_panel(app_mgr) -> InProjectPanel:
	var panel := InProjectPanel.new()
	panel.panel_size = Vector2(512, 768)
	panel._app_manager = app_mgr
	return panel


func _ready() -> void:
	super._ready()

	_project_manager = _app_manager.project_manager
	_interaction = _app_manager.interaction
	_project_space = _app_manager.project_space
	# Navigation is not unique-named, so find it via parent
	_navigation = _app_manager.get_node_or_null("../Navigation")

	_build_ui()
	_connect_signals()
	_refresh_spline_list()
	_update_mode_buttons()
	_update_props()


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
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel_container.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	# --- Top row: Close, Undo, Redo, Reset ---
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 4)
	vbox.add_child(top_row)

	var close_btn := _make_button("Close", top_row)
	close_btn.pressed.connect(_on_close_pressed)

	_undo_btn = _make_button("Undo", top_row)
	_undo_btn.pressed.connect(_on_undo_pressed)

	_redo_btn = _make_button("Redo", top_row)
	_redo_btn.pressed.connect(_on_redo_pressed)

	var reset_btn := _make_button("Reset", top_row)
	reset_btn.pressed.connect(_on_reset_pressed)

	# --- Mode selection row ---
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 2)
	vbox.add_child(mode_row)

	_mode_group = ButtonGroup.new()
	var mode_names := ["Move", "Draw", "Extrude", "Size", "Weight"]
	for i in mode_names.size():
		var btn := Button.new()
		btn.text = mode_names[i]
		btn.toggle_mode = true
		btn.button_group = _mode_group
		btn.add_theme_font_size_override("font_size", 18)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_mode_pressed.bind(i))
		mode_row.add_child(btn)
		_mode_buttons.append(btn)

	# --- Curve Accuracy slider (Draw mode only) ---
	_accuracy_container = HBoxContainer.new()
	_accuracy_container.add_theme_constant_override("separation", 6)
	vbox.add_child(_accuracy_container)

	var acc_label := Label.new()
	acc_label.text = "Accuracy"
	acc_label.add_theme_font_size_override("font_size", 18)
	acc_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	_accuracy_container.add_child(acc_label)

	_accuracy_slider = HSlider.new()
	_accuracy_slider.min_value = 0.0
	_accuracy_slider.max_value = 1.0
	_accuracy_slider.step = 0.05
	_accuracy_slider.value = _interaction.curve_accuracy
	_accuracy_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_accuracy_slider.value_changed.connect(_on_accuracy_changed)
	_accuracy_container.add_child(_accuracy_slider)

	# --- Separator ---
	vbox.add_child(HSeparator.new())

	# --- Spline list ---
	_spline_scroll = ScrollContainer.new()
	_spline_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_spline_scroll.custom_minimum_size = Vector2(0, 200)
	vbox.add_child(_spline_scroll)

	_spline_list_container = VBoxContainer.new()
	_spline_list_container.add_theme_constant_override("separation", 2)
	_spline_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_spline_scroll.add_child(_spline_list_container)

	_empty_label = Label.new()
	_empty_label.text = "add a spline by drawing"
	_empty_label.add_theme_font_size_override("font_size", 18)
	_empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_spline_list_container.add_child(_empty_label)

	# --- Separator ---
	vbox.add_child(HSeparator.new())

	# --- Selected spline properties ---
	_props_container = VBoxContainer.new()
	_props_container.add_theme_constant_override("separation", 4)
	vbox.add_child(_props_container)

	var props_title := Label.new()
	props_title.text = "Spline Properties"
	props_title.add_theme_font_size_override("font_size", 18)
	props_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_props_container.add_child(props_title)

	# Order U
	var order_row := HBoxContainer.new()
	order_row.add_theme_constant_override("separation", 6)
	_props_container.add_child(order_row)
	var order_label := Label.new()
	order_label.text = "Order U"
	order_label.add_theme_font_size_override("font_size", 18)
	order_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	order_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	order_row.add_child(order_label)
	_order_spin = SpinBox.new()
	_order_spin.min_value = 2
	_order_spin.max_value = 20
	_order_spin.value = 4
	_order_spin.add_theme_font_size_override("font_size", 18)
	_order_spin.value_changed.connect(_on_order_changed)
	order_row.add_child(_order_spin)

	# Resolution U
	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override("separation", 6)
	_props_container.add_child(res_row)
	var res_label := Label.new()
	res_label.text = "Resolution U"
	res_label.add_theme_font_size_override("font_size", 18)
	res_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	res_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_row.add_child(res_label)
	_resolution_spin = SpinBox.new()
	_resolution_spin.min_value = 1
	_resolution_spin.max_value = 32
	_resolution_spin.value = 8
	_resolution_spin.add_theme_font_size_override("font_size", 18)
	_resolution_spin.value_changed.connect(_on_resolution_changed)
	res_row.add_child(_resolution_spin)

	# Cyclic
	var cyclic_row := HBoxContainer.new()
	cyclic_row.add_theme_constant_override("separation", 6)
	_props_container.add_child(cyclic_row)
	var cyclic_label := Label.new()
	cyclic_label.text = "Cyclic"
	cyclic_label.add_theme_font_size_override("font_size", 18)
	cyclic_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
	cyclic_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cyclic_row.add_child(cyclic_label)
	_cyclic_check = CheckButton.new()
	_cyclic_check.toggled.connect(_on_cyclic_toggled)
	cyclic_row.add_child(_cyclic_check)

	content_root.add_child(panel_container)


func _connect_signals() -> void:
	_project_space.splines_changed.connect(_refresh_spline_list)
	_interaction.spline_selected.connect(_on_spline_selected)
	_interaction.mode_changed.connect(_on_mode_changed)


func _process(delta: float) -> void:
	super._process(delta)

	# Update undo/redo button enabled state
	if _undo_btn:
		_undo_btn.disabled = not _project_manager.can_undo()
	if _redo_btn:
		_redo_btn.disabled = not _project_manager.can_redo()


# --- Button handlers ---

func _on_close_pressed() -> void:
	_app_manager.close_project()


func _on_undo_pressed() -> void:
	if _project_manager.can_undo():
		_project_manager.undo()


func _on_redo_pressed() -> void:
	if _project_manager.can_redo():
		_project_manager.redo()


func _on_reset_pressed() -> void:
	if _navigation:
		_navigation._reset_view()
	_app_manager.reset_panel_position()


func _on_mode_pressed(mode_index: int) -> void:
	# Mode enum order: DRAW=0, MOVE=1, EXTRUDE=2, SIZE=3, WEIGHT=4
	# Button order: Move=0, Draw=1, Extrude=2, Size=3, Weight=4
	var mode_map := [
		_interaction.Mode.MOVE,
		_interaction.Mode.DRAW,
		_interaction.Mode.EXTRUDE,
		_interaction.Mode.SIZE,
		_interaction.Mode.WEIGHT,
	]
	_interaction.set_mode(mode_map[mode_index])


func _on_mode_changed(_mode) -> void:
	_update_mode_buttons()


func _update_mode_buttons() -> void:
	# Map Mode enum to button index
	var mode_to_btn := {
		_interaction.Mode.MOVE: 0,
		_interaction.Mode.DRAW: 1,
		_interaction.Mode.EXTRUDE: 2,
		_interaction.Mode.SIZE: 3,
		_interaction.Mode.WEIGHT: 4,
	}
	var btn_index: int = mode_to_btn.get(_interaction.current_mode, 1)
	if btn_index < _mode_buttons.size():
		_mode_buttons[btn_index].button_pressed = true

	# Show/hide accuracy slider based on Draw mode
	_accuracy_container.visible = _interaction.current_mode == _interaction.Mode.DRAW


func _on_accuracy_changed(value: float) -> void:
	_interaction.set_curve_accuracy(value)


# --- Spline list ---

func _refresh_spline_list() -> void:
	# Clear existing rows
	for row_data in _spline_rows:
		if is_instance_valid(row_data["node"]):
			row_data["node"].queue_free()
	_spline_rows.clear()

	# Gather current SplineNodes
	var splines: Array[SplineNode] = []
	for child in _project_space.get_children():
		if child is SplineNode:
			splines.append(child as SplineNode)

	_empty_label.visible = splines.is_empty()

	for i in splines.size():
		var sn := splines[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)

		var select_btn := Button.new()
		select_btn.text = "Spline %d" % (i + 1)
		select_btn.add_theme_font_size_override("font_size", 18)
		select_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		select_btn.pressed.connect(_on_spline_select_pressed.bind(sn))
		row.add_child(select_btn)

		# Highlight selected spline
		if sn == _interaction.selected_spline:
			select_btn.add_theme_color_override("font_color", Color(0.3, 0.8, 1.0))

		var del_btn := Button.new()
		del_btn.text = "X"
		del_btn.add_theme_font_size_override("font_size", 18)
		del_btn.custom_minimum_size = Vector2(40, 0)
		del_btn.pressed.connect(_on_spline_delete_pressed.bind(sn))
		row.add_child(del_btn)

		_spline_list_container.add_child(row)
		_spline_rows.append({"node": row, "spline": sn})


func _on_spline_select_pressed(spline: SplineNode) -> void:
	_interaction.select_spline(spline)


func _on_spline_delete_pressed(spline: SplineNode) -> void:
	if not is_instance_valid(spline):
		return
	# If deleting the selected spline, clear selection
	if _interaction.selected_spline == spline:
		_interaction.select_spline(null)
	spline.free()
	_project_manager.autosave()
	# List will refresh via splines_changed signal


func _on_spline_selected(_spline: SplineNode) -> void:
	_update_props()
	_refresh_spline_list()  # Update highlight


# --- Spline properties ---

func _update_props() -> void:
	var spline: SplineNode = _interaction.selected_spline
	var has_selection := spline != null and is_instance_valid(spline) and spline.data != null

	_props_container.visible = has_selection

	if has_selection:
		_updating_props = true
		_order_spin.value = spline.data.order_u
		_resolution_spin.value = spline.data.resolution_u
		_cyclic_check.button_pressed = spline.data.cyclic
		_updating_props = false


func _on_order_changed(value: float) -> void:
	if _updating_props:
		return
	var spline: SplineNode = _interaction.selected_spline
	if spline and is_instance_valid(spline) and spline.data:
		spline.data.order_u = int(value)
		spline.mark_dirty()
		_project_manager.autosave()


func _on_resolution_changed(value: float) -> void:
	if _updating_props:
		return
	var spline: SplineNode = _interaction.selected_spline
	if spline and is_instance_valid(spline) and spline.data:
		spline.data.resolution_u = int(value)
		spline.mark_dirty()
		_project_manager.autosave()


func _on_cyclic_toggled(toggled_on: bool) -> void:
	if _updating_props:
		return
	var spline: SplineNode = _interaction.selected_spline
	if spline and is_instance_valid(spline) and spline.data:
		spline.data.cyclic = toggled_on
		spline.mark_dirty()
		_project_manager.autosave()


# --- Helpers ---

func _make_button(text: String, parent: Control) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 18)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(btn)
	return btn
