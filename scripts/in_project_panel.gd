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
var _snap_btn: Button
var _mirror_btn: Button
var _options_container: PanelContainer
var _options_content: VBoxContainer
var _options_title: Label
var _snap_options_container: VBoxContainer
var _mirror_options_container: VBoxContainer
var _spline_list_stack: Control
var _spline_list_container: VBoxContainer
var _spline_scroll: ScrollContainer
var _empty_label: Label
var _props_container: Control
var _order_spin: SpinBox
var _cyclic_check: CheckButton
var _snap_pos_check: CheckButton
var _snap_size_check: CheckButton
var _snap_weight_check: CheckButton
var _snap_pos_step: SpinBox
var _snap_size_step: SpinBox
var _snap_weight_step: SpinBox
var _mirror_x_check: CheckButton
var _mirror_y_check: CheckButton
var _mirror_z_check: CheckButton
var _radial_check: CheckButton
var _radial_axis_buttons: Array[Button] = []
var _radial_axis_group: ButtonGroup
var _radial_copies_spin: SpinBox

# Track spline list items for efficient updates
var _spline_rows: Array[Dictionary] = []  # [{node: HBoxContainer, spline: SplineNode}]

# Suppress property change signals during programmatic updates
var _updating_props: bool = false
var _active_options_panel: String = ""

const OPTIONS_NONE := ""
const OPTIONS_SNAP := "snap"
const OPTIONS_MIRROR := "mirror"
const PANEL_UI_SCENE := preload("res://scenes/ui/in_project_panel_ui.tscn")


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
	_update_options_buttons()


func _build_ui() -> void:
	var ui := PANEL_UI_SCENE.instantiate() as Control
	content_root.add_child(ui)

	var close_btn := ui.find_child("CloseButton", true, false) as Button
	close_btn.pressed.connect(_on_close_pressed)

	_undo_btn = ui.find_child("UndoButton", true, false) as Button
	_undo_btn.pressed.connect(_on_undo_pressed)

	_redo_btn = ui.find_child("RedoButton", true, false) as Button
	_redo_btn.pressed.connect(_on_redo_pressed)

	var reset_btn := ui.find_child("ResetButton", true, false) as Button
	reset_btn.pressed.connect(_on_reset_pressed)

	_mode_group = ButtonGroup.new()
	_mode_buttons = [
		ui.find_child("SizeButton", true, false) as Button,
		ui.find_child("WeightButton", true, false) as Button,
	]
	for i in _mode_buttons.size():
		_mode_buttons[i].button_group = _mode_group
		_mode_buttons[i].pressed.connect(_on_mode_pressed.bind(i))

	_accuracy_container = ui.find_child("AccuracyRow", true, false) as HBoxContainer
	if _accuracy_container == null:
		_accuracy_container = ui.find_child("ModeRow", true, false) as HBoxContainer
	_accuracy_slider = ui.find_child("SmoothnessSlider", true, false) as HSlider
	_accuracy_slider.value = _interaction.curve_smoothness
	_accuracy_slider.value_changed.connect(_on_accuracy_changed)

	_snap_btn = ui.find_child("SnapButton", true, false) as Button
	_snap_btn.pressed.connect(_on_snap_options_pressed)

	_mirror_btn = ui.find_child("MirrorButton", true, false) as Button
	_mirror_btn.pressed.connect(_on_mirror_options_pressed)

	_spline_list_stack = ui.find_child("SplineListStack", true, false) as Control
	_spline_scroll = ui.find_child("SplineScroll", true, false) as ScrollContainer
	_spline_list_container = ui.find_child("SplineList", true, false) as VBoxContainer
	_empty_label = ui.find_child("EmptyLabel", true, false) as Label

	_options_container = ui.find_child("OptionsOverlay", true, false) as PanelContainer
	_options_content = ui.find_child("OptionsContent", true, false) as VBoxContainer
	_options_title = ui.find_child("OptionsTitle", true, false) as Label
	_snap_options_container = ui.find_child("SnapOptions", true, false) as VBoxContainer
	_mirror_options_container = ui.find_child("MirrorOptions", true, false) as VBoxContainer

	_snap_pos_check = ui.find_child("SnapPositionCheck", true, false) as CheckButton
	_snap_pos_step = ui.find_child("SnapPositionStep", true, false) as SpinBox
	_snap_pos_check.toggled.connect(_on_snap_pos_toggled)
	_snap_pos_step.value_changed.connect(_on_snap_pos_step_changed)
	_wire_snap_step_keyboard(_snap_pos_step)

	_snap_size_check = ui.find_child("SnapSizeCheck", true, false) as CheckButton
	_snap_size_step = ui.find_child("SnapSizeStep", true, false) as SpinBox
	_snap_size_check.toggled.connect(_on_snap_size_toggled)
	_snap_size_step.value_changed.connect(_on_snap_size_step_changed)
	_wire_snap_step_keyboard(_snap_size_step)

	_snap_weight_check = ui.find_child("SnapWeightCheck", true, false) as CheckButton
	_snap_weight_step = ui.find_child("SnapWeightStep", true, false) as SpinBox
	_snap_weight_check.toggled.connect(_on_snap_weight_toggled)
	_snap_weight_step.value_changed.connect(_on_snap_weight_step_changed)
	_wire_snap_step_keyboard(_snap_weight_step)
	_refresh_snap_checks()

	_mirror_x_check = ui.find_child("MirrorXCheck", true, false) as CheckButton
	_mirror_y_check = ui.find_child("MirrorYCheck", true, false) as CheckButton
	_mirror_z_check = ui.find_child("MirrorZCheck", true, false) as CheckButton
	_mirror_x_check.toggled.connect(_on_mirror_x_toggled)
	_mirror_y_check.toggled.connect(_on_mirror_y_toggled)
	_mirror_z_check.toggled.connect(_on_mirror_z_toggled)

	_radial_check = ui.find_child("RadialCheck", true, false) as CheckButton
	_radial_check.toggled.connect(_on_radial_toggled)
	_radial_axis_group = ButtonGroup.new()
	_radial_axis_buttons = [
		ui.find_child("RadialAxisXButton", true, false) as Button,
		ui.find_child("RadialAxisYButton", true, false) as Button,
		ui.find_child("RadialAxisZButton", true, false) as Button,
	]
	for i in _radial_axis_buttons.size():
		_radial_axis_buttons[i].button_group = _radial_axis_group
		_radial_axis_buttons[i].pressed.connect(_on_radial_axis_pressed.bind(i))
	_radial_copies_spin = ui.find_child("RadialCopiesSpin", true, false) as SpinBox
	_radial_copies_spin.value_changed.connect(_on_radial_copies_changed)
	_wire_snap_step_keyboard(_radial_copies_spin)
	_refresh_symmetry_checks()

	_props_container = ui.find_child("PropsContainer", true, false) as Control
	if _props_container == null:
		_props_container = ui.find_child("BottomRow", true, false) as Control
	_order_spin = ui.find_child("OrderSpin", true, false) as SpinBox
	_order_spin.value_changed.connect(_on_order_changed)
	var order_le := _order_spin.get_line_edit()
	order_le.gui_input.connect(_on_order_le_gui_input)
	order_le.focus_exited.connect(_on_order_focus_exited)

	_cyclic_check = ui.find_child("CyclicCheck", true, false) as CheckButton
	_cyclic_check.toggled.connect(_on_cyclic_toggled)


func _connect_signals() -> void:
	_project_space.splines_changed.connect(_refresh_spline_list)
	_interaction.spline_selected.connect(_on_spline_selected)
	_interaction.mode_changed.connect(_on_mode_changed)
	_interaction.snap_settings_changed.connect(_refresh_snap_checks)
	_interaction.symmetry_settings_changed.connect(_refresh_symmetry_checks)


# --- Snap toggles ---

## Reuse the numpad keyboard. gui_input filter ensures clicking the up/down
## arrows doesn't pop the keyboard — only a direct click on the text area.
func _wire_snap_step_keyboard(spin: SpinBox) -> void:
	var le := spin.get_line_edit()
	le.gui_input.connect(_on_snap_step_le_gui_input.bind(spin))
	le.focus_exited.connect(_on_snap_step_focus_exited.bind(spin))


func _on_snap_pos_toggled(on: bool) -> void:
	_interaction.set_snap_position_enabled(on)
	_update_options_buttons()


func _on_snap_size_toggled(on: bool) -> void:
	_interaction.set_snap_size_enabled(on)
	_update_options_buttons()


func _on_snap_weight_toggled(on: bool) -> void:
	_interaction.set_snap_weight_enabled(on)
	_update_options_buttons()


func _on_snap_pos_step_changed(value: float) -> void:
	_interaction.set_snap_position_step(value)


func _on_snap_size_step_changed(value: float) -> void:
	_interaction.set_snap_size_step(value)


func _on_snap_weight_step_changed(value: float) -> void:
	_interaction.set_snap_weight_step(value)


func _on_snap_step_le_gui_input(event: InputEvent, spin: SpinBox) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_app_manager.request_keyboard(spin, "numpad", self)


func _on_snap_step_focus_exited(spin: SpinBox) -> void:
	await get_tree().process_frame
	var kb: XRKeyboard = _app_manager._active_keyboard
	if not kb or not is_instance_valid(kb):
		return
	if kb.target_control == spin and not spin.get_line_edit().has_focus():
		_app_manager.dismiss_keyboard()


## Re-sync the snap UI from interaction state. Called when a project is loaded
## or undo/redo restores a different snap configuration. Uses *_no_signal
## variants so writes don't re-trigger the setters.
func _refresh_snap_checks() -> void:
	if _snap_pos_check:
		_snap_pos_check.set_pressed_no_signal(_interaction.snap_position_enabled)
	if _snap_size_check:
		_snap_size_check.set_pressed_no_signal(_interaction.snap_size_enabled)
	if _snap_weight_check:
		_snap_weight_check.set_pressed_no_signal(_interaction.snap_weight_enabled)
	if _snap_pos_step:
		_snap_pos_step.set_value_no_signal(_interaction.snap_position_step)
	if _snap_size_step:
		_snap_size_step.set_value_no_signal(_interaction.snap_size_step)
	if _snap_weight_step:
		_snap_weight_step.set_value_no_signal(_interaction.snap_weight_step)
	_update_options_buttons()


func _on_mirror_x_toggled(on: bool) -> void:
	_interaction.set_mirror_axis_enabled(0, on)
	_update_options_buttons()


func _on_mirror_y_toggled(on: bool) -> void:
	_interaction.set_mirror_axis_enabled(1, on)
	_update_options_buttons()


func _on_mirror_z_toggled(on: bool) -> void:
	_interaction.set_mirror_axis_enabled(2, on)
	_update_options_buttons()


func _on_radial_toggled(on: bool) -> void:
	_interaction.set_radial_enabled(on)
	_update_options_buttons()


func _on_radial_axis_pressed(axis: int) -> void:
	_interaction.set_radial_axis(axis)


func _on_radial_copies_changed(value: float) -> void:
	_interaction.set_radial_copies(int(value))


func _refresh_symmetry_checks() -> void:
	if _mirror_x_check:
		_mirror_x_check.set_pressed_no_signal(_interaction.mirror_x_enabled)
	if _mirror_y_check:
		_mirror_y_check.set_pressed_no_signal(_interaction.mirror_y_enabled)
	if _mirror_z_check:
		_mirror_z_check.set_pressed_no_signal(_interaction.mirror_z_enabled)
	if _radial_check:
		_radial_check.set_pressed_no_signal(_interaction.radial_enabled)
	for i in _radial_axis_buttons.size():
		if _radial_axis_buttons[i]:
			_radial_axis_buttons[i].set_pressed_no_signal(i == _interaction.radial_axis)
	if _radial_copies_spin:
		_radial_copies_spin.set_value_no_signal(_interaction.radial_copies)
	_update_options_buttons()


func _on_snap_options_pressed() -> void:
	_set_options_panel(OPTIONS_NONE if _active_options_panel == OPTIONS_SNAP else OPTIONS_SNAP)


func _on_mirror_options_pressed() -> void:
	_set_options_panel(OPTIONS_NONE if _active_options_panel == OPTIONS_MIRROR else OPTIONS_MIRROR)


func _set_options_panel(panel_name: String) -> void:
	_active_options_panel = panel_name

	var showing_options := panel_name != OPTIONS_NONE
	_options_container.visible = showing_options

	_snap_options_container.visible = panel_name == OPTIONS_SNAP
	_mirror_options_container.visible = panel_name == OPTIONS_MIRROR

	if panel_name == OPTIONS_SNAP:
		_options_title.text = "Snapping"
	elif panel_name == OPTIONS_MIRROR:
		_options_title.text = "Mirror"

	_update_options_buttons()


func _update_options_buttons() -> void:
	if _snap_btn:
		_snap_btn.text = "Snap •" if _snap_options_enabled() else "Snap"
		_snap_btn.set_pressed_no_signal(_active_options_panel == OPTIONS_SNAP)
	if _mirror_btn:
		_mirror_btn.text = "Mirror •" if _mirror_options_enabled() else "Mirror"
		_mirror_btn.set_pressed_no_signal(_active_options_panel == OPTIONS_MIRROR)


func _snap_options_enabled() -> bool:
	return (
		_interaction.snap_position_enabled
		or _interaction.snap_size_enabled
		or _interaction.snap_weight_enabled
	)


func _mirror_options_enabled() -> bool:
	return (
		_interaction.mirror_x_enabled
		or _interaction.mirror_y_enabled
		or _interaction.mirror_z_enabled
		or _interaction.radial_enabled
	)


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
	# Button order: Size=0, Weight=1
	var mode_map := [
		_interaction.Mode.SIZE,
		_interaction.Mode.WEIGHT,
	]
	_interaction.set_mode(mode_map[mode_index])


func _on_mode_changed(_mode) -> void:
	_update_mode_buttons()


func _update_mode_buttons() -> void:
	# Map Mode enum to button index
	var mode_to_btn := {
		_interaction.Mode.SIZE: 0,
		_interaction.Mode.WEIGHT: 1,
	}
	var btn_index: int = mode_to_btn.get(_interaction.current_mode, 0)
	if btn_index < _mode_buttons.size():
		_mode_buttons[btn_index].button_pressed = true


func _on_accuracy_changed(value: float) -> void:
	_interaction.set_curve_smoothness(value)


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



func _on_order_le_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_app_manager.request_keyboard(_order_spin, "numpad", self)


func _on_order_focus_exited() -> void:
	await get_tree().process_frame
	var kb: XRKeyboard = _app_manager._active_keyboard
	if not kb or not is_instance_valid(kb):
		return
	if kb.target_control == _order_spin and not _order_spin.get_line_edit().has_focus():
		_app_manager.dismiss_keyboard()


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
