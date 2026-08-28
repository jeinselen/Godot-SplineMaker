extends Node3D

## Manages hover detection, trigger state, haptic feedback, joystick routing,
## draw mode recording, and realtime mesh preview.

@onready var left_controller: XRController3D = %LeftController
@onready var right_controller: XRController3D = %RightController
@onready var project_space: Node3D = %ProjectSpace
@onready var project_manager: Node = %ProjectManager
@onready var app_manager: Node = %AppManager
@onready var navigation: Node = get_parent().get_node_or_null("Navigation")

var left_action_area: ActionArea
var right_action_area: ActionArea

# Floating value readout per controller; visible only during joystick size/weight
# editing. Displays the active value to 2 decimals.
var _left_value_label: Label3D
var _right_value_label: Label3D

# Mode state — Size and Weight control joystick behavior on hovered points
enum Mode { SIZE, WEIGHT }
var current_mode: Mode = Mode.SIZE
var curve_smoothness: float = 0.5  # 0.0 = smoothest, 1.0 = tightest fit

# Stroke-width source — Pressure (trigger travel) or Speed (hand velocity).
# Applies globally to both controllers, like current_mode. Persisted per-project.
enum WidthSource { PRESSURE, SPEED }
var width_source: WidthSource = WidthSource.PRESSURE
# Falloff sensitivity shared by both width sources. 0.5 reproduces the original
# hard-coded squared curve; below 0.5 = less sensitive (needs more input for the
# same width), above 0.5 = more sensitive (linear response lands around 0.75).
var draw_sensitivity: float = 0.5

## Sensitivity exponent sweep, anchored at the midpoint so 0.5 preserves the
## original pow(input, 2) behavior. exponent = MID * RANGE^(1 - 2*sensitivity):
## 0.5 -> ^2 (old squared), 0.0 -> ^8 (least sensitive), 1.0 -> ^0.5 (most
## sensitive); linear (^1) falls near sensitivity 0.75.
const SENSITIVITY_MID_EXP := 2.0
const SENSITIVITY_RANGE := 4.0
## When true, the sensitivity curve is passed through smoothstep to soften the
## extreme ends (no abrupt start/stop in width). Left OFF for now — testing the
## bare exponent first; flip to true to evaluate the softened variant.
const SENSITIVITY_USE_SMOOTHSTEP := false

# Real-world controller speed (m/s), low-pass filtered, for Speed width mode.
# Filtered every frame in _process so a value is ready when a stroke begins.
var _left_draw_speed: float = 0.0
var _right_draw_speed: float = 0.0
var _left_prev_world_pos: Vector3 = Vector3.ZERO
var _right_prev_world_pos: Vector3 = Vector3.ZERO
var _speed_tracking_initialized: bool = false

# Snapping state — toggles and increments persist per-project (saved in
# project_manager's serialized state).
var snap_position_enabled: bool = false
var snap_size_enabled: bool = false
var snap_weight_enabled: bool = false
var snap_position_step: float = 0.1
var snap_size_step: float = 0.1
var snap_weight_step: float = 1.0
const SIZE_MIN := 0.001
const WEIGHT_MIN := 0.01

# Selected spline tracking
var selected_spline: SplineNode = null
signal spline_selected(spline: SplineNode)
signal mode_changed(mode: Mode)
## Fired after project_manager restores snap state (load / undo / redo) so the
## panel can sync its CheckButtons. Not emitted by the setters themselves —
## those are user-driven from the panel.
signal snap_settings_changed
signal symmetry_settings_changed
## Fired after project_manager restores width-source / sensitivity state so the
## panel can sync its slider and Pressure/Speed toggle.
signal draw_settings_changed

# Mirroring and radial symmetry are project-level virtual transforms. Spline
# data stores only the authored points; SplineNode materializes editable copies.
var mirror_x_enabled: bool = false
var mirror_y_enabled: bool = false
var mirror_z_enabled: bool = false
var radial_enabled: bool = false
var radial_axis: int = 1 # 0=X, 1=Y, 2=Z
var radial_copies: int = 6
var _symmetry_transforms: Array[Basis] = [Basis.IDENTITY]

# Per-controller state
var _left_trigger_active: bool = false
var _right_trigger_active: bool = false
var _left_trigger_value: float = 0.0
var _right_trigger_value: float = 0.0
var _left_joystick: Vector2 = Vector2.ZERO
var _right_joystick: Vector2 = Vector2.ZERO

# Track which points each controller is hovering
var _left_hover_set: Array[Dictionary] = []
var _right_hover_set: Array[Dictionary] = []

# Haptic state
var _left_was_hovering: bool = false
var _right_was_hovering: bool = false

# Draw mode state (per controller for simultaneous drawing)
var _left_drawing: bool = false
var _right_drawing: bool = false
var _left_stroke: DrawStroke = null
var _right_stroke: DrawStroke = null
var _left_trigger_floor: float = 0.0
var _right_trigger_floor: float = 0.0

# Extrude/insert state: tracks newly created points being moved by trigger hold
# Single-point: {spline, index} — snaps to controller position
# Multi-point: {spline, index, initial_pos} — delta-transform like grip
var _left_extruding: Array[Dictionary] = []
var _right_extruding: Array[Dictionary] = []
var _extrude_multi: Array[bool] = [false, false]  # true when multi-point extrude
var _extrude_initial_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _extrude_initial_basis: Array[Basis] = [Basis.IDENTITY, Basis.IDENTITY]
var _extrude_scale: Array[float] = [1.0, 1.0]

# Grip-translate state (per controller): grip moves hovered points instead of project space
var _left_grip_translating: bool = false
var _right_grip_translating: bool = false
var _left_grip_initial_pos: Vector3 = Vector3.ZERO
var _right_grip_initial_pos: Vector3 = Vector3.ZERO
# Snapshot of grabbed points: Array of {spline: SplineNode, index: int, initial_pos: Vector3}
var _left_grip_grabbed: Array[Dictionary] = []
var _right_grip_grabbed: Array[Dictionary] = []
var _left_grip_initial_basis: Basis = Basis.IDENTITY
var _right_grip_initial_basis: Basis = Basis.IDENTITY
var _left_grip_scale: float = 1.0
var _right_grip_scale: float = 1.0
# Orientation lock: a trigger press during a grip drag toggles this on, freezing
# the grabbed points at their original orientation (translation + scale only, no
# rotation). Reset each time a grip drag begins.
var _left_grip_orient_locked: bool = false
var _right_grip_orient_locked: bool = false

# Warning popup state
var _short_draw_warned: bool = false

# Track whether joystick edits occurred (for autosave on hover change)
var _joystick_edited: bool = false

# Continuous accumulators for size/weight joystick edits. Keyed by
# "spline_instance_id:index". Holds the unsnapped running value so snapping
# doesn't freeze the value at one grid line. Cleared when the joystick drops
# back through the deadzone.
var _left_edit_accum: Dictionary = {}
var _right_edit_accum: Dictionary = {}
var _left_editing_active: bool = false
var _right_editing_active: bool = false

# Tracks the preview mesh settings that have already paid their cold-start
# allocation/commit costs. The first real stroke should never do this work.
var _warmed_draw_pipeline_keys: Dictionary = {}
var _draw_pipeline_warmup_parent: Node3D = null

const GRIP_SCALE_SPEED := 1.5
const GRIP_SCALE_MIN := 0.05
const GRIP_SCALE_MAX := 20.0

const CONTROLLER_ID_LEFT := 0
const CONTROLLER_ID_RIGHT := 1

# --- MX Ink stylus (standalone, per-hand — "Stylus Native") ---
# The stylus reports on whichever hand holds it and emits stylus_* actions no
# ordinary controller sends, so it's handled entirely per-hand (ambidextrous, no
# coupling). Two input groups, mutually exclusive on a first-come basis per hand:
#   Pressure group (tip/side, squishy): empty=draw, hovering=grab/rotate points,
#     menu: tip=click / side=grab panel. Extrude is intentionally NOT on the stylus.
#   Button group (front/back, crisp): a quick still tap = redo/undo; a hold =
#     continuous mode. Front-hold = joystick emulation (L/R motion → active-area
#     size when empty, point width/weight when hovering). Back-hold = navigate the
#     view (grip; combine with a controller grip for dual-grip move/rotate/scale).
#     Hovering: front = width/weight adjust, back = delete. Menu: both click.
# Stylus feel constants (gates, hold delay, adjust spans) live in SettingsData.

# Pressure group (tip/side share one gesture per hand)
var _stylus_tip_raw: Array[float] = [0.0, 0.0]
var _stylus_side_raw: Array[float] = [0.0, 0.0]
var _stylus_tip_gated: Array[bool] = [false, false]
var _stylus_side_gated: Array[bool] = [false, false]
var _stylus_pressure_sm: Array[float] = [0.0, 0.0]
var _stylus_press_active: Array[bool] = [false, false]
var _stylus_press_gesture: Array[String] = ["", ""]  # "draw" | "grab" | "menu"
var _stylus_menu_click: Array[bool] = [false, false]  # tip clicked a UI panel
var _stylus_menu_grab: Array[bool] = [false, false]   # side grabbed a UI panel

# Button group (front/back): quick still tap vs. deferred hold
var _stylus_front_mode: Array[String] = ["", ""]  # "empty" | "hover" | "menu"
var _stylus_back_mode: Array[String] = ["", ""]
var _stylus_front_time: Array[float] = [0.0, 0.0]
var _stylus_back_time: Array[float] = [0.0, 0.0]
var _stylus_front_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _stylus_back_pos: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _stylus_front_started: Array[bool] = [false, false]  # front-hold adjust began
var _stylus_back_started: Array[bool] = [false, false]   # back-hold navigate began
# During back-hold navigation, a side press toggles navigation's yaw lock. The
# side gate is read directly (the press group is owner-blocked by the back
# button); this tracks the previous gate reading so each press (rising edge) is
# one toggle, matching the controller trigger.
var _stylus_yaw_side: Array[bool] = [false, false]

# Front-hold drag-adjust: direct displacement → value, with the selection locked.
var _stylus_adjust_mode: Array[String] = ["", ""]  # "size" | "points"
var _stylus_adjust_is_weight: Array[bool] = [false, false]
var _stylus_adjust_start_radius: Array[float] = [0.0, 0.0]
var _stylus_adjust_origin: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _stylus_adjust_right: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var _stylus_hover_locked: Array[bool] = [false, false]
var _stylus_adjust_points_l: Array[Dictionary] = []  # {spline, index, start}
var _stylus_adjust_points_r: Array[Dictionary] = []

# First-come mutual exclusion between the pressure and button groups, per hand.
var _stylus_owner: Array[String] = ["", ""]  # "" | "press" | "button"


func _ready() -> void:
	# Create action areas as children of controllers
	left_action_area = ActionArea.new()
	left_action_area.name = "ActionArea"
	left_controller.add_child(left_action_area)

	right_action_area = ActionArea.new()
	right_action_area.name = "ActionArea"
	right_controller.add_child(right_action_area)

	_left_value_label = _make_value_label()
	left_controller.add_child(_left_value_label)
	_right_value_label = _make_value_label()
	right_controller.add_child(_right_value_label)

	# Connect input signals
	left_controller.button_pressed.connect(_on_button_pressed.bind(CONTROLLER_ID_LEFT))
	left_controller.button_released.connect(_on_button_released.bind(CONTROLLER_ID_LEFT))
	left_controller.input_float_changed.connect(_on_float_changed.bind(CONTROLLER_ID_LEFT))
	left_controller.input_vector2_changed.connect(_on_vector2_changed.bind(CONTROLLER_ID_LEFT))

	right_controller.button_pressed.connect(_on_button_pressed.bind(CONTROLLER_ID_RIGHT))
	right_controller.button_released.connect(_on_button_released.bind(CONTROLLER_ID_RIGHT))
	right_controller.input_float_changed.connect(_on_float_changed.bind(CONTROLLER_ID_RIGHT))
	right_controller.input_vector2_changed.connect(_on_vector2_changed.bind(CONTROLLER_ID_RIGHT))

	call_deferred("warm_up_drawing_pipeline")


func _process(delta: float) -> void:
	# Keep filtered controller speed current every frame so Speed-mode width has
	# a settled value the instant a stroke begins.
	_update_controller_speed(delta)

	# Advance stylus crisp-button holds (deferred navigate / drag-adjust).
	_update_stylus_hold(CONTROLLER_ID_LEFT)
	_update_stylus_hold(CONTROLLER_ID_RIGHT)

	# --- Priority system ---
	# 1. Hovered control points (highest) — blocks panel interaction entirely
	# 2. Pointing at panel — blocks drawing and project space navigation
	# 3. Empty space (lowest) — drawing, action area resize, project space navigation

	# Run hover detection unless this hand is mid-edit — while drawing, grabbing/
	# moving points, extruding, or running a stylus drag-adjust, the highlighted
	# selection is frozen so it can't bleed onto other points the moving action
	# area passes over. (Applies uniformly to controllers and the stylus.)
	if not _hover_locked(CONTROLLER_ID_LEFT) and left_action_area.visible:
		_update_hover(CONTROLLER_ID_LEFT, left_controller, left_action_area)
	if not _hover_locked(CONTROLLER_ID_RIGHT) and right_action_area.visible:
		_update_hover(CONTROLLER_ID_RIGHT, right_controller, right_action_area)

	# Block panel interaction for controllers that have hovered points
	var left_hovering := not _left_hover_set.is_empty()
	var right_hovering := not _right_hover_set.is_empty()
	var panel: XRPanel = app_manager.active_panel
	if panel and is_instance_valid(panel):
		panel.set_controller_blocked(CONTROLLER_ID_LEFT, left_hovering)
		panel.set_controller_blocked(CONTROLLER_ID_RIGHT, right_hovering)

	# Check panel state (after blocking, so blocked controllers read as not pointing)
	var left_on_panel: bool = app_manager.is_pointing_at_panel(CONTROLLER_ID_LEFT)
	var right_on_panel: bool = app_manager.is_pointing_at_panel(CONTROLLER_ID_RIGHT)

	# Joystick behavior:
	# Grip-translating or extruding → joystick scales point positions (handled below)
	# Hovering points (idle) → edit size/weight based on mode
	# Pointing at panel → panel handles scroll
	# Neither → resize action area
	var left_busy := _left_grip_translating or not _left_extruding.is_empty()
	var right_busy := _right_grip_translating or not _right_extruding.is_empty()
	# Action areas snap to the same step as point sizes when size-snap is on.
	var aa_snap := snap_size_step if snap_size_enabled else 0.0
	left_action_area.snap_step = aa_snap
	right_action_area.snap_step = aa_snap
	# While a keyboard is open, suppress all joystick-driven point edits and
	# action-area resizing so the user can type without side effects. End any
	# in-progress edit session so the value label hides too.
	var kb_active: bool = app_manager.is_keyboard_active()
	if kb_active:
		_end_joystick_edit_session(CONTROLLER_ID_LEFT)
		_end_joystick_edit_session(CONTROLLER_ID_RIGHT)
	# The stylus drag-adjust drives size/width/weight directly, so skip the normal
	# joystick handling for a hand while its adjust is active.
	var left_adjusting := _stylus_adjust_mode[CONTROLLER_ID_LEFT] != ""
	var right_adjusting := _stylus_adjust_mode[CONTROLLER_ID_RIGHT] != ""
	if left_action_area.visible and not kb_active and not left_adjusting:
		if left_hovering and not left_busy:
			_update_joystick_edit(CONTROLLER_ID_LEFT, delta)
		elif not left_on_panel and not left_busy:
			left_action_area.update_size(_left_joystick.y, delta)
	if right_action_area.visible and not kb_active and not right_adjusting:
		if right_hovering and not right_busy:
			_update_joystick_edit(CONTROLLER_ID_RIGHT, delta)
		elif not right_on_panel and not right_busy:
			right_action_area.update_size(_right_joystick.y, delta)

	# Scale grabbed/extruded points via joystick Y while grip or multi-extrude is active
	if _left_grip_translating:
		var joy_y := _left_joystick.y
		if absf(joy_y) >= 0.1:
			_left_grip_scale = clampf(_left_grip_scale * (1.0 + joy_y * GRIP_SCALE_SPEED * delta), GRIP_SCALE_MIN, GRIP_SCALE_MAX)
	if _right_grip_translating:
		var joy_y := _right_joystick.y
		if absf(joy_y) >= 0.1:
			_right_grip_scale = clampf(_right_grip_scale * (1.0 + joy_y * GRIP_SCALE_SPEED * delta), GRIP_SCALE_MIN, GRIP_SCALE_MAX)
	if _extrude_multi[CONTROLLER_ID_LEFT] and not _left_extruding.is_empty():
		var joy_y := _left_joystick.y
		if absf(joy_y) >= 0.1:
			_extrude_scale[CONTROLLER_ID_LEFT] = clampf(_extrude_scale[CONTROLLER_ID_LEFT] * (1.0 + joy_y * GRIP_SCALE_SPEED * delta), GRIP_SCALE_MIN, GRIP_SCALE_MAX)
	if _extrude_multi[CONTROLLER_ID_RIGHT] and not _right_extruding.is_empty():
		var joy_y := _right_joystick.y
		if absf(joy_y) >= 0.1:
			_extrude_scale[CONTROLLER_ID_RIGHT] = clampf(_extrude_scale[CONTROLLER_ID_RIGHT] * (1.0 + joy_y * GRIP_SCALE_SPEED * delta), GRIP_SCALE_MIN, GRIP_SCALE_MAX)

	# Grip-transform: rotate, scale, and translate grabbed points with controller
	if _left_grip_translating:
		_update_grip_transform(CONTROLLER_ID_LEFT)
	if _right_grip_translating:
		_update_grip_transform(CONTROLLER_ID_RIGHT)

	# Update extruded/inserted point positions
	if not _left_extruding.is_empty():
		_update_extrude(CONTROLLER_ID_LEFT)
	if not _right_extruding.is_empty():
		_update_extrude(CONTROLLER_ID_RIGHT)

	# Draw mode: update strokes
	if _left_drawing:
		_update_stroke(CONTROLLER_ID_LEFT)
	if _right_drawing:
		_update_stroke(CONTROLLER_ID_RIGHT)

	# Haptic buzz while actively editing
	if _left_trigger_active and (not _left_extruding.is_empty() or _left_drawing):
		Haptics.buzz(left_controller)
	if _right_trigger_active and (not _right_extruding.is_empty() or _right_drawing):
		Haptics.buzz(right_controller)
	if _left_grip_translating:
		Haptics.buzz(left_controller)
	if _right_grip_translating:
		Haptics.buzz(right_controller)


## Build and briefly attach the same resources used by the first live stroke.
## This shifts GDScript class setup, material creation, SurfaceTool commit, and
## ArrayMesh assignment out of the first controller-draw frame.
func warm_up_drawing_pipeline(mesh_edge_count: int = -1, spline_resolution: int = -1) -> void:
	if mesh_edge_count <= 0:
		mesh_edge_count = app_manager.settings.preview_mesh_resolution
	if spline_resolution <= 0:
		spline_resolution = app_manager.settings.preview_spline_resolution

	var warmup_key := "%d:%d" % [mesh_edge_count, spline_resolution]
	if _warmed_draw_pipeline_keys.has(warmup_key):
		return
	_warmed_draw_pipeline_keys[warmup_key] = true

	if _draw_pipeline_warmup_parent and is_instance_valid(_draw_pipeline_warmup_parent):
		_draw_pipeline_warmup_parent.queue_free()

	var parent := Node3D.new()
	parent.name = "DrawingPipelineWarmup"
	parent.visible = false
	add_child(parent)
	_draw_pipeline_warmup_parent = parent

	var warm_data := SplineData.new()
	warm_data.order_u = 3
	warm_data.add_point(Vector3(-0.04, 0.0, 0.0), 0.01)
	warm_data.add_point(Vector3(0.0, 0.02, 0.0), 0.012)
	warm_data.add_point(Vector3(0.04, 0.0, 0.0), 0.01)

	var warm_spline := SplineNode.new()
	warm_spline.name = "WarmSpline"
	warm_spline.mesh_edge_count = mesh_edge_count
	warm_spline.spline_resolution = spline_resolution
	warm_spline.set_data(warm_data)
	parent.add_child(warm_spline)
	warm_spline.set_active(true)
	warm_spline.rebuild_mesh()
	warm_spline._rebuild_control_points()
	warm_spline.set_selected(true)
	warm_spline.set_point_hovered(0, true, CONTROLLER_ID_LEFT)
	warm_spline.set_point_hovered(0, false, CONTROLLER_ID_LEFT)
	warm_spline.set_selected(false)

	var tip_material := StandardMaterial3D.new()
	tip_material.albedo_color = SplineNode.COLOR_NEUTRAL
	var tip_mesh_instance := MeshInstance3D.new()
	tip_mesh_instance.name = "WarmDrawTip"
	tip_mesh_instance.material_override = tip_material
	parent.add_child(tip_mesh_instance)

	var tip_points := PackedVector3Array([
		Vector3.ZERO,
		Vector3(0.025, 0.0, 0.0),
		Vector3(0.05, 0.01, 0.0),
	])
	var tip_sizes := PackedFloat32Array([0.01, 0.011, 0.012])
	tip_mesh_instance.mesh = TubeMesh.generate(tip_points, tip_sizes, mesh_edge_count, false)

	await get_tree().process_frame
	if is_instance_valid(parent):
		parent.queue_free()
	if _draw_pipeline_warmup_parent == parent:
		_draw_pipeline_warmup_parent = null


# --- Hover detection ---

func _update_hover(controller_id: int, controller: XRController3D, action_area: ActionArea) -> void:
	var area_global_pos := controller.global_position
	var area_radius := action_area.radius

	var area_local_pos := project_space.global_transform.affine_inverse() * area_global_pos
	var ps_scale := project_space.global_transform.basis.get_scale().x
	var local_radius := area_radius / ps_scale if ps_scale > 0.0001 else area_radius

	var prev_hover_set := _get_hover_set(controller_id)
	var new_hover_set: Array[Dictionary] = []

	for child in project_space.get_children():
		if child is SplineNode:
			var spline_node := child as SplineNode
			if not spline_node.data:
				continue
			for visible_entry in spline_node.get_visible_point_entries():
				var pt: Vector3 = visible_entry["position"]
				if area_local_pos.distance_to(pt) <= local_radius:
					new_hover_set.append({
						"spline": spline_node,
						"index": visible_entry["index"],
						"symmetry_index": visible_entry["symmetry_index"],
					})

	# Diff: unhover points no longer in set
	for entry in prev_hover_set:
		if not _hover_set_contains(new_hover_set, entry):
			(entry["spline"] as SplineNode).set_point_hovered(entry["index"], false, controller_id, _entry_symmetry_index(entry))

	# Diff: hover new points
	for entry in new_hover_set:
		if not _hover_set_contains(prev_hover_set, entry):
			(entry["spline"] as SplineNode).set_point_hovered(entry["index"], true, controller_id, _entry_symmetry_index(entry))

	# Detect if the hover set actually changed
	var hover_changed := prev_hover_set.size() != new_hover_set.size()
	if not hover_changed:
		for entry in new_hover_set:
			if not _hover_set_contains(prev_hover_set, entry):
				hover_changed = true
				break

	_set_hover_set(controller_id, new_hover_set)

	# If joystick edits were made and the hover set changed, trigger autosave
	if hover_changed and _joystick_edited:
		_joystick_edited = false
		project_manager.autosave()

	action_area.resize_locked = not new_hover_set.is_empty()
	action_area.set_highlight(not new_hover_set.is_empty())

	# Haptic tap on first hover entry
	var was_hovering := _left_was_hovering if controller_id == CONTROLLER_ID_LEFT else _right_was_hovering
	var is_hovering := not new_hover_set.is_empty()
	if is_hovering and not was_hovering:
		var ctrl := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
		Haptics.tap(ctrl)
	if controller_id == CONTROLLER_ID_LEFT:
		_left_was_hovering = is_hovering
	else:
		_right_was_hovering = is_hovering


func _hover_set_contains(hover_set: Array[Dictionary], entry: Dictionary) -> bool:
	for e in hover_set:
		if e["spline"] == entry["spline"] and e["index"] == entry["index"] and _entry_symmetry_index(e) == _entry_symmetry_index(entry):
			return true
	return false


func _canonical_hover_set(hover_set: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen := {}
	for entry in hover_set:
		var sn := entry["spline"] as SplineNode
		var key := "%d:%d" % [sn.get_instance_id(), int(entry["index"])]
		if seen.has(key):
			continue
		seen[key] = true
		result.append(entry)
	return result


func _entry_symmetry_index(entry: Dictionary) -> int:
	return int(entry.get("symmetry_index", 0))


func _entry_to_base_position(entry: Dictionary, visible_pos: Vector3) -> Vector3:
	var sn := entry["spline"] as SplineNode
	return sn.symmetry_to_base(visible_pos, _entry_symmetry_index(entry))


func _controller_basis_in_base(controller: XRController3D, symmetry_basis: Basis) -> Basis:
	var ps_inv_basis := project_space.global_transform.basis.inverse()
	return symmetry_basis.inverse() * ps_inv_basis * controller.global_transform.basis


func _get_hover_set(controller_id: int) -> Array[Dictionary]:
	return _left_hover_set if controller_id == CONTROLLER_ID_LEFT else _right_hover_set


func _set_hover_set(controller_id: int, hover_set: Array[Dictionary]) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		_left_hover_set = hover_set
	else:
		_right_hover_set = hover_set


# --- Draw mode ---

func _begin_drawing(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var action_area := left_action_area if controller_id == CONTROLLER_ID_LEFT else right_action_area

	var pos := project_space.global_transform.affine_inverse() * controller.global_position
	pos = snap_pos(pos)
	var size_val := _get_draw_size(controller_id, action_area)

	# Capture the trigger value at click time as the floor for remapping
	var trigger_val := _left_trigger_value if controller_id == CONTROLLER_ID_LEFT else _right_trigger_value
	if controller_id == CONTROLLER_ID_LEFT:
		_left_trigger_floor = trigger_val
	else:
		_right_trigger_floor = trigger_val

	var stroke := DrawStroke.new()
	stroke.smoothing = curve_smoothness
	stroke.mesh_edge_count = app_manager.settings.preview_mesh_resolution
	stroke.spline_resolution = app_manager.settings.preview_spline_resolution
	stroke.snap_position_step = snap_position_step if snap_position_enabled else 0.0
	stroke.symmetry_transforms = _symmetry_transforms
	stroke.begin(pos, size_val, project_space)

	if controller_id == CONTROLLER_ID_LEFT:
		_left_drawing = true
		_left_stroke = stroke
	else:
		_right_drawing = true
		_right_stroke = stroke


func _update_stroke(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var action_area := left_action_area if controller_id == CONTROLLER_ID_LEFT else right_action_area
	var stroke := _left_stroke if controller_id == CONTROLLER_ID_LEFT else _right_stroke

	if not stroke:
		return

	var pos := project_space.global_transform.affine_inverse() * controller.global_position
	var size_val := _get_draw_size(controller_id, action_area)
	stroke.update(pos, size_val)


func _finalize_drawing(controller_id: int) -> void:
	var stroke := _left_stroke if controller_id == CONTROLLER_ID_LEFT else _right_stroke
	var action_area := left_action_area if controller_id == CONTROLLER_ID_LEFT else right_action_area

	if not stroke:
		_clear_draw_state(controller_id)
		return

	var total_length := stroke.finalize()

	# Check minimum viable spline length
	var ps_scale := project_space.global_transform.basis.get_scale().x
	var min_length := (action_area.radius * 2.0) / ps_scale if ps_scale > 0.0001 else action_area.radius * 2.0

	if total_length < min_length or stroke.data.point_count() < 2:
		stroke.cancel()
		if not _short_draw_warned:
			_short_draw_warned = true
			_show_short_draw_warning(controller_id)
	else:
		# Stroke is already finalized — just mark it as a permanent spline
		if stroke.spline_node:
			stroke.spline_node.set_symmetry_transforms(_symmetry_transforms)
			stroke.spline_node.set_active(true)
			stroke.spline_node.name = "Spline"
			select_spline(stroke.spline_node)

	_clear_draw_state(controller_id)


func _cancel_drawing(controller_id: int) -> void:
	var stroke := _left_stroke if controller_id == CONTROLLER_ID_LEFT else _right_stroke
	if stroke:
		stroke.cancel()
	_clear_draw_state(controller_id)


func _clear_draw_state(controller_id: int) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		_left_drawing = false
		_left_stroke = null
	else:
		_right_drawing = false
		_right_stroke = null


func _get_draw_size(controller_id: int, action_area: ActionArea) -> float:
	# Raw [0,1] width input: 0 = thinnest, 1 = thickest (full action-area radius).
	# Pressure and Speed feed the same sensitivity curve so the rest of the
	# pipeline is source-agnostic.
	var input := _get_width_input(controller_id)
	var curved := _apply_sensitivity(input)

	var ps_scale := project_space.global_transform.basis.get_scale().x
	var local_radius := action_area.radius / ps_scale if ps_scale > 0.0001 else action_area.radius
	var min_size := local_radius * 0.01
	return lerpf(min_size, local_radius, curved)


## Returns the raw [0,1] width driver for the active source, before sensitivity.
## 0 = thinnest stroke, 1 = thickest (full action-area radius).
func _get_width_input(controller_id: int) -> float:
	if width_source == WidthSource.SPEED:
		var speed := _left_draw_speed if controller_id == CONTROLLER_ID_LEFT else _right_draw_speed
		var max_speed: float = app_manager.settings.max_draw_speed
		# Normalize speed to [0,1]; slow = thick, fast = thin (hence 1.0 - t).
		var t := clampf(speed / max_speed, 0.0, 1.0) if max_speed > 0.0001 else 0.0
		return 1.0 - t

	# Pressure: remap trigger travel from [floor, 1.0] to [0.0, 1.0] so the full
	# range is usable after the click that started the stroke.
	var trigger_val := _left_trigger_value if controller_id == CONTROLLER_ID_LEFT else _right_trigger_value
	var trigger_floor := _left_trigger_floor if controller_id == CONTROLLER_ID_LEFT else _right_trigger_floor
	var range_size := 1.0 - trigger_floor
	return clampf((trigger_val - trigger_floor) / range_size, 0.0, 1.0) if range_size > 0.01 else 0.0


## Shapes a raw [0,1] width input by the shared sensitivity setting.
## sensitivity 0.5 → pow(input, 2) (original squared curve); 0.0 → pow(input, 8)
## (least sensitive); 1.0 → pow(input, 0.5) (most sensitive). The exponent sweeps
## geometrically as MID * RANGE^(1 - 2*sensitivity), smooth through the midpoint.
func _apply_sensitivity(input: float) -> float:
	var clamped := clampf(input, 0.0, 1.0)
	var s := clampf(draw_sensitivity, 0.0, 1.0)
	var exponent := SENSITIVITY_MID_EXP * pow(SENSITIVITY_RANGE, 1.0 - 2.0 * s)
	var curved := pow(clamped, exponent)
	if SENSITIVITY_USE_SMOOTHSTEP:
		# Soften both ends so width never starts or stops abruptly.
		curved = smoothstep(0.0, 1.0, curved)
	return curved


## Low-pass filters each controller's real-world speed (m/s). Filtering strength
## is tied to the Smooth slider — same expression draw_stroke uses for cursor lag
## — so a higher Smooth setting calms width jitter in Speed mode.
func _update_controller_speed(delta: float) -> void:
	if delta <= 0.0:
		return
	var left_pos := left_controller.global_position
	var right_pos := right_controller.global_position

	if not _speed_tracking_initialized:
		_left_prev_world_pos = left_pos
		_right_prev_world_pos = right_pos
		_speed_tracking_initialized = true
		return

	var left_raw := (left_pos - _left_prev_world_pos).length() / delta
	var right_raw := (right_pos - _right_prev_world_pos).length() / delta
	_left_prev_world_pos = left_pos
	_right_prev_world_pos = right_pos

	var follow := lerpf(0.12, 0.7, 1.0 - curve_smoothness)
	_left_draw_speed = lerpf(_left_draw_speed, left_raw, follow)
	_right_draw_speed = lerpf(_right_draw_speed, right_raw, follow)


func _show_short_draw_warning(_controller_id: int) -> void:
	app_manager.show_popup(
		"Draw longer to create a spline\n(must be larger than the action area)",
		Color(1.0, 0.9, 0.3),
		30.0
	)


# --- Extrude / Insert ---

func _begin_extrude_or_insert(controller_id: int, hover_set: Array[Dictionary]) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	hover_set = _canonical_hover_set(hover_set)
	var ctrl_visible_pos := project_space.global_transform.affine_inverse() * controller.global_position

	# Separate endpoints from mid-points
	var endpoints: Array[Dictionary] = []
	var midpoints: Array[Dictionary] = []
	for entry in hover_set:
		var sn := entry["spline"] as SplineNode
		if sn.data.is_endpoint(entry["index"]):
			endpoints.append(entry)
		else:
			midpoints.append(entry)

	var new_points: Array[Dictionary] = []
	var is_multi := false

	if not endpoints.is_empty():
		is_multi = endpoints.size() > 1

		for entry in endpoints:
			var sn := entry["spline"] as SplineNode
			var idx: int = entry["index"]
			var src_pos := sn.data.points[idx]
			var src_size := sn.data.sizes[idx]
			var src_weight := sn.data.weights[idx]
			# Single: snap to controller. Multi: keep at source position.
			var new_pos := snap_pos(_entry_to_base_position(entry, ctrl_visible_pos)) if not is_multi else snap_pos(src_pos)
			var new_idx: int
			if idx == 0:
				sn.data.insert_point(0, new_pos, src_size, src_weight)
				new_idx = 0
			else:
				sn.data.add_point(new_pos, src_size, src_weight)
				new_idx = sn.data.point_count() - 1
			sn.mark_dirty()
			sn.set_point_editing(new_idx, true, _entry_symmetry_index(entry))
			new_points.append({"spline": sn, "index": new_idx, "initial_pos": new_pos, "symmetry_index": _entry_symmetry_index(entry)})
	else:
		# Insert mid-points: only lowest index per spline
		is_multi = midpoints.size() > 1
		var per_spline: Dictionary = {}  # SplineNode → lowest index entry
		for entry in midpoints:
			var sn := entry["spline"] as SplineNode
			if not per_spline.has(sn) or entry["index"] < per_spline[sn]["index"]:
				per_spline[sn] = entry

		is_multi = per_spline.size() > 1

		for sn: SplineNode in per_spline:
			var entry: Dictionary = per_spline[sn]
			var idx: int = entry["index"]
			var next_idx := idx + 1
			var avg_size := (sn.data.sizes[idx] + sn.data.sizes[next_idx]) * 0.5
			var avg_weight := (sn.data.weights[idx] + sn.data.weights[next_idx]) * 0.5
			# Single: snap to controller. Multi: place at midpoint between neighbors.
			var new_pos := snap_pos(_entry_to_base_position(entry, ctrl_visible_pos)) if not is_multi else snap_pos((sn.data.points[idx] + sn.data.points[next_idx]) * 0.5)
			sn.data.insert_point(next_idx, new_pos, avg_size, avg_weight)
			sn.mark_dirty()
			sn.set_point_editing(next_idx, true, _entry_symmetry_index(entry))
			new_points.append({"spline": sn, "index": next_idx, "initial_pos": new_pos, "symmetry_index": _entry_symmetry_index(entry)})

	# Store extrude state
	_extrude_multi[controller_id] = is_multi
	_extrude_scale[controller_id] = 1.0
	if is_multi and not new_points.is_empty():
		# Snapshot controller transform for delta-transform (like grip)
		var first_entry := new_points[0]
		var first_sn := first_entry["spline"] as SplineNode
		var first_symmetry_index := _entry_symmetry_index(first_entry)
		var first_basis: Basis = first_sn.get_symmetry_transforms()[first_symmetry_index]
		_extrude_initial_pos[controller_id] = first_sn.symmetry_to_base(ctrl_visible_pos, first_symmetry_index)
		_extrude_initial_basis[controller_id] = _controller_basis_in_base(controller, first_basis)

	if controller_id == CONTROLLER_ID_LEFT:
		_left_extruding = new_points
	else:
		_right_extruding = new_points


func _update_extrude(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var extruding := _left_extruding if controller_id == CONTROLLER_ID_LEFT else _right_extruding
	var ctrl_visible_pos := project_space.global_transform.affine_inverse() * controller.global_position

	if not _extrude_multi[controller_id]:
		for entry in extruding:
			var sn := entry["spline"] as SplineNode
			var idx: int = entry["index"]
			var snapped_pos := snap_pos(_entry_to_base_position(entry, ctrl_visible_pos))
			sn.data.points[idx] = snapped_pos
			sn.mark_dirty()
	else:
		# Multi point: delta-transform (translation + rotation + scale)
		var initial_pos := _extrude_initial_pos[controller_id]
		var initial_basis := _extrude_initial_basis[controller_id]
		var ext_scale := _extrude_scale[controller_id]

		var first_entry := extruding[0]
		var first_sn := first_entry["spline"] as SplineNode
		var first_symmetry_index := _entry_symmetry_index(first_entry)
		var first_basis: Basis = first_sn.get_symmetry_transforms()[first_symmetry_index]
		var ctrl_base_pos := first_sn.symmetry_to_base(ctrl_visible_pos, first_symmetry_index)
		var translate_delta := ctrl_base_pos - initial_pos

		var current_local_basis := _controller_basis_in_base(controller, first_basis)
		var rotation_delta := current_local_basis * initial_basis.inverse()

		for entry in extruding:
			var sn := entry["spline"] as SplineNode
			var idx: int = entry["index"]
			var original: Vector3 = entry["initial_pos"]
			var offset := original - initial_pos
			sn.data.points[idx] = snap_pos(initial_pos + rotation_delta * offset * ext_scale + translate_delta)
			sn.mark_dirty()


# --- Delete points (A/X button) ---

func _on_delete_pressed(controller_id: int) -> void:
	if is_input_active():
		return
	if not left_action_area.visible:
		return

	var hover_set := _canonical_hover_set(_get_hover_set(controller_id))
	if hover_set.is_empty():
		return

	# Group by spline, collect indices in descending order for safe removal
	var per_spline: Dictionary = {}  # SplineNode → Array[int]
	for entry in hover_set:
		var sn := entry["spline"] as SplineNode
		if not per_spline.has(sn):
			per_spline[sn] = []
		per_spline[sn].append(entry["index"])

	var splines_to_remove: Array[SplineNode] = []

	for sn: SplineNode in per_spline:
		var indices: Array = per_spline[sn]
		indices.sort()
		indices.reverse()  # Remove from highest index first

		var remaining := sn.data.point_count() - indices.size()
		if remaining <= 1:
			# Spline would have 0 or 1 points — remove entirely
			splines_to_remove.append(sn)
		else:
			for idx in indices:
				sn.data.remove_point(idx)
			sn.mark_dirty()

	# Deletion shifted point indices out from under the index-keyed hover state
	# (on both controllers, and the nodes themselves), so fully reset hover and
	# let next frame's _update_hover re-derive it from controller positions.
	clear_hover_sets()

	# Remove splines that are too short
	for sn in splines_to_remove:
		if selected_spline == sn:
			select_spline(null)
		sn.queue_free()

	# Auto-select another spline if selection was cleared
	if selected_spline == null or not is_instance_valid(selected_spline):
		var fallback: SplineNode = null
		for child in project_space.get_children():
			if child is SplineNode and child.is_active and not child.is_queued_for_deletion():
				fallback = child
		if fallback:
			select_spline(fallback)

	project_manager.autosave()


# --- Joystick size/weight editing ---

const SIZE_EDIT_SPEED := 0.15
const WEIGHT_EDIT_SPEED := 2.0

func _update_joystick_edit(controller_id: int, delta: float) -> void:
	var joy_y := _left_joystick.y if controller_id == CONTROLLER_ID_LEFT else _right_joystick.y

	# Deadzone: end any active edit session and clear accumulators so the next
	# edit starts fresh from the current point values.
	if absf(joy_y) < 0.1:
		_end_joystick_edit_session(controller_id)
		return

	var hover_set := _canonical_hover_set(_get_hover_set(controller_id))
	if hover_set.is_empty():
		_end_joystick_edit_session(controller_id)
		return

	# Normalize to 0–1 after deadzone, preserve sign, then square for fine control at low deflection
	var sign_y := signf(joy_y)
	var normalized := clampf((absf(joy_y) - 0.1) / 0.9, 0.0, 1.0)
	var curved := sign_y * normalized * normalized

	var speed := SIZE_EDIT_SPEED if current_mode == Mode.SIZE else WEIGHT_EDIT_SPEED
	var change := curved * speed * delta

	var accum := _left_edit_accum if controller_id == CONTROLLER_ID_LEFT else _right_edit_accum
	if controller_id == CONTROLLER_ID_LEFT:
		_left_editing_active = true
	else:
		_right_editing_active = true

	_joystick_edited = true
	var first_snapped := 0.0
	for i in hover_set.size():
		var entry: Dictionary = hover_set[i]
		var sn := entry["spline"] as SplineNode
		var idx: int = entry["index"]
		var key := _accum_key(entry)

		var raw: float
		if accum.has(key):
			raw = accum[key]
		elif current_mode == Mode.SIZE:
			raw = sn.data.sizes[idx]
		else:
			raw = sn.data.weights[idx]

		raw += change
		accum[key] = raw

		var snapped_value: float
		if current_mode == Mode.SIZE:
			snapped_value = snap_size_value(raw)
			sn.data.sizes[idx] = snapped_value
		else:
			snapped_value = snap_weight_value(raw)
			sn.data.weights[idx] = snapped_value
		sn.mark_dirty()

		if i == 0:
			first_snapped = snapped_value

	_update_value_label(controller_id, first_snapped)


func _make_value_label() -> Label3D:
	var lbl := Label3D.new()
	lbl.text = ""
	lbl.font_size = 64
	lbl.outline_size = 16
	lbl.modulate = Color(1, 1, 1, 1)
	lbl.outline_modulate = Color(0, 0, 0, 0.85)
	lbl.pixel_size = 0.0006
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lbl.no_depth_test = true
	lbl.fixed_size = true
	lbl.position = Vector3(0.0, 0.08, 0.0)
	lbl.visible = false
	return lbl


func _update_value_label(controller_id: int, value: float) -> void:
	var lbl := _left_value_label if controller_id == CONTROLLER_ID_LEFT else _right_value_label
	if not lbl:
		return
	lbl.text = "%.2f" % value
	lbl.visible = true


func _hide_value_label(controller_id: int) -> void:
	var lbl := _left_value_label if controller_id == CONTROLLER_ID_LEFT else _right_value_label
	if lbl:
		lbl.visible = false


func _accum_key(entry: Dictionary) -> String:
	var sn := entry["spline"] as SplineNode
	return str(sn.get_instance_id()) + ":" + str(entry["index"])


func _end_joystick_edit_session(controller_id: int) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		if _left_editing_active:
			_left_edit_accum.clear()
			_left_editing_active = false
	else:
		if _right_editing_active:
			_right_edit_accum.clear()
			_right_editing_active = false
	_hide_value_label(controller_id)


# --- Helpers for project_manager ---

## Returns true while any trigger or grip translate is active on either controller.
## Used by project_manager to suppress undo/redo during active input.
func is_input_active() -> bool:
	return _left_trigger_active or _right_trigger_active \
		or _left_grip_translating or _right_grip_translating


## Restores action area radii after loading a save file.
func restore_action_area_sizes(left_radius: float, right_radius: float) -> void:
	left_action_area.radius = left_radius
	left_action_area._apply_radius()
	right_action_area.radius = right_radius
	right_action_area._apply_radius()


## Full hover reset: clears both controllers' hover sets and the node-side
## highlight on every spline, so the next _update_hover re-derives highlights
## from actual controller positions. Call after any structural edit that shifts
## point indices (delete, merge) — index-keyed hover state goes stale otherwise —
## and before project_manager frees SplineNodes during restore, so the hover diff
## loop can't touch dangling nodes.
func clear_hover_sets() -> void:
	_left_hover_set = []
	_right_hover_set = []
	_left_was_hovering = false
	_right_was_hovering = false
	for child in project_space.get_children():
		if child is SplineNode:
			(child as SplineNode).clear_hover_state()


## Show or hide the action area spheres on controllers.
func set_action_areas_visible(vis: bool) -> void:
	left_action_area.visible = vis
	right_action_area.visible = vis


## Set the current editing mode. Called by the in-project panel.
func set_mode(mode: Mode) -> void:
	current_mode = mode
	# Mode swap invalidates per-point accumulators (they hold size or weight,
	# not both); a fresh session reseeds from the point's current value.
	_left_edit_accum.clear()
	_right_edit_accum.clear()
	_left_editing_active = false
	_right_editing_active = false
	mode_changed.emit(mode)


## Set the curve accuracy for draw mode. Called by the panel slider.
func set_curve_smoothness(value: float) -> void:
	curve_smoothness = clampf(value, 0.0, 1.0)


## Set the shared stroke-width sensitivity. Called by the panel slider.
func set_draw_sensitivity(value: float) -> void:
	draw_sensitivity = clampf(value, 0.0, 1.0)
	project_manager.autosave()


## Select the stroke-width source (Pressure or Speed). Called by the panel
## toggle. Applies to both controllers.
func set_width_source(source: WidthSource) -> void:
	width_source = source
	project_manager.autosave()


## Called by project_manager after restoring saved state (open / undo / redo).
## Fires draw_settings_changed so the panel can refresh its slider and toggle.
func restore_draw_settings(sensitivity: float, source: int) -> void:
	draw_sensitivity = clampf(sensitivity, 0.0, 1.0)
	width_source = WidthSource.SPEED if source == WidthSource.SPEED else WidthSource.PRESSURE
	draw_settings_changed.emit()


# --- Snap helpers ---

## Snap a position vector to the position-snap grid (no-op if disabled).
func snap_pos(p: Vector3) -> Vector3:
	if not snap_position_enabled or snap_position_step <= 0.0:
		return p
	var s := snap_position_step
	return Vector3(
		round(p.x / s) * s,
		round(p.y / s) * s,
		round(p.z / s) * s,
	)


## Snap a size value to the size-snap grid (no-op if disabled). Always clamped
## to SIZE_MIN so the 0.0 slot becomes the absolute minimum.
func snap_size_value(v: float) -> float:
	if not snap_size_enabled or snap_size_step <= 0.0:
		return maxf(SIZE_MIN, v)
	return maxf(SIZE_MIN, round(v / snap_size_step) * snap_size_step)


## Snap a weight value to the weight-snap grid (no-op if disabled). Always
## clamped to WEIGHT_MIN.
func snap_weight_value(v: float) -> float:
	if not snap_weight_enabled or snap_weight_step <= 0.0:
		return maxf(WEIGHT_MIN, v)
	return maxf(WEIGHT_MIN, round(v / snap_weight_step) * snap_weight_step)


# --- Snap setters (called by in-project panel; persist via autosave) ---

func set_snap_position_enabled(on: bool) -> void:
	snap_position_enabled = on
	project_manager.autosave()


func set_snap_size_enabled(on: bool) -> void:
	snap_size_enabled = on
	project_manager.autosave()


func set_snap_weight_enabled(on: bool) -> void:
	snap_weight_enabled = on
	project_manager.autosave()


const SNAP_STEP_MIN := 0.01
const SNAP_STEP_MAX := 1.0


func set_snap_position_step(step: float) -> void:
	snap_position_step = clampf(step, SNAP_STEP_MIN, SNAP_STEP_MAX)
	project_manager.autosave()


func set_snap_size_step(step: float) -> void:
	snap_size_step = clampf(step, SNAP_STEP_MIN, SNAP_STEP_MAX)
	project_manager.autosave()


func set_snap_weight_step(step: float) -> void:
	snap_weight_step = clampf(step, SNAP_STEP_MIN, SNAP_STEP_MAX)
	project_manager.autosave()


## Run adjacent-duplicate merge on each spline (used at end of grip/extrude
## release so points that landed on the same snap cell collapse cleanly).
## Refreshes the mesh and clears hover state for any merged-away points.
func _merge_duplicates_on(splines: Array[SplineNode]) -> void:
	for sn in splines:
		if not is_instance_valid(sn) or sn.data == null:
			continue
		if sn.data.merge_adjacent_duplicates():
			# Hover indices could now be stale — clear them to be safe.
			clear_hover_sets()
			sn.mark_dirty()


## Called by project_manager after restoring saved state (open / undo / redo).
## Fires snap_settings_changed so the panel can refresh its CheckButtons.
func restore_snap_settings(
	pos_en: bool, size_en: bool, weight_en: bool,
	pos_step: float, size_step: float, weight_step: float,
) -> void:
	snap_position_enabled = pos_en
	snap_size_enabled = size_en
	snap_weight_enabled = weight_en
	snap_position_step = clampf(pos_step, SNAP_STEP_MIN, SNAP_STEP_MAX)
	snap_size_step = clampf(size_step, SNAP_STEP_MIN, SNAP_STEP_MAX)
	snap_weight_step = clampf(weight_step, SNAP_STEP_MIN, SNAP_STEP_MAX)
	snap_settings_changed.emit()


# --- Symmetry setters (called by in-project panel; persist via autosave) ---

func set_mirror_axis_enabled(axis: int, on: bool) -> void:
	if axis == 0:
		mirror_x_enabled = on
	elif axis == 1:
		mirror_y_enabled = on
	elif axis == 2:
		mirror_z_enabled = on
	_rebuild_symmetry_transforms()
	project_manager.autosave()


func set_radial_enabled(on: bool) -> void:
	radial_enabled = on
	_rebuild_symmetry_transforms()
	project_manager.autosave()


func set_radial_axis(axis: int) -> void:
	radial_axis = clampi(axis, 0, 2)
	_rebuild_symmetry_transforms()
	project_manager.autosave()


func set_radial_copies(copies: int) -> void:
	radial_copies = clampi(copies, 2, 32)
	_rebuild_symmetry_transforms()
	project_manager.autosave()


func restore_symmetry_settings(
	mirror_x: bool, mirror_y: bool, mirror_z: bool,
	radial_on: bool, radial_axis_value: int, radial_copy_count: int,
) -> void:
	mirror_x_enabled = mirror_x
	mirror_y_enabled = mirror_y
	mirror_z_enabled = mirror_z
	radial_enabled = radial_on
	radial_axis = clampi(radial_axis_value, 0, 2)
	radial_copies = clampi(radial_copy_count, 2, 32)
	_rebuild_symmetry_transforms(false)
	symmetry_settings_changed.emit()


func _rebuild_symmetry_transforms(notify: bool = true) -> void:
	_symmetry_transforms = _make_symmetry_transforms()
	for child in project_space.get_children():
		if child is SplineNode:
			(child as SplineNode).set_symmetry_transforms(_symmetry_transforms)
	if notify:
		symmetry_settings_changed.emit()


func _make_symmetry_transforms() -> Array[Basis]:
	var mirror_transforms: Array[Basis] = [Basis.IDENTITY]
	var mirror_axes := [
		mirror_x_enabled,
		mirror_y_enabled,
		mirror_z_enabled,
	]
	for axis in 3:
		if not mirror_axes[axis]:
			continue
		var next_transforms := mirror_transforms.duplicate()
		var mirror_basis := _mirror_basis(axis)
		for xf in mirror_transforms:
			next_transforms.append(mirror_basis * xf)
		mirror_transforms = next_transforms

	var radial_transforms: Array[Basis] = [Basis.IDENTITY]
	if radial_enabled:
		radial_transforms.clear()
		for i in radial_copies:
			var angle := TAU * float(i) / float(radial_copies)
			radial_transforms.append(_radial_basis(radial_axis, angle))

	var result: Array[Basis] = []
	var keys := {}
	for radial_xf in radial_transforms:
		for mirror_xf in mirror_transforms:
			var xf := radial_xf * mirror_xf
			var key := _basis_key(xf)
			if keys.has(key):
				continue
			keys[key] = true
			result.append(xf)
	return result


func _mirror_basis(axis: int) -> Basis:
	if axis == 0:
		return Basis(Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1))
	if axis == 1:
		return Basis(Vector3(1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))
	return Basis(Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1))


func _radial_basis(axis: int, angle: float) -> Basis:
	if axis == 0:
		return Basis(Vector3.RIGHT, angle)
	if axis == 1:
		return Basis(Vector3.UP, angle)
	return Basis(Vector3(0, 0, 1), angle)


func _basis_key(b: Basis) -> String:
	var values := [
		b.x.x, b.x.y, b.x.z,
		b.y.x, b.y.y, b.y.z,
		b.z.x, b.z.y, b.z.z,
	]
	var parts: Array[String] = []
	for value in values:
		parts.append(str(round(value * 100000.0) / 100000.0))
	return ",".join(parts)


## Select a spline (from panel list click or from interaction).
func select_spline(spline: SplineNode) -> void:
	if selected_spline == spline:
		return
	# Deselect visual on previously selected spline
	if selected_spline and is_instance_valid(selected_spline):
		selected_spline.set_selected(false)
	selected_spline = spline
	if spline and is_instance_valid(spline):
		spline.set_selected(true)
	spline_selected.emit(spline)


# --- Input signal handlers ---

func _on_button_pressed(button_name: String, controller_id: int) -> void:
	if button_name == "trigger_click":
		_on_trigger_pressed(controller_id)
	elif button_name == "grip_click":
		_on_grip_pressed(controller_id)
	elif button_name == "stylus_front":
		_stylus_button_press(controller_id, true)
	elif button_name == "stylus_back":
		_stylus_button_press(controller_id, false)
	elif button_name == "stylus_docked":
		_stylus_reset(controller_id)
	elif button_name == "ax_button":
		var hover_set := _canonical_hover_set(_get_hover_set(controller_id))
		if not hover_set.is_empty() and left_action_area.visible:
			_on_delete_pressed(controller_id)
		elif not is_input_active():
			project_manager.undo()
	elif button_name == "by_button":
		if not is_input_active():
			project_manager.redo()


func _on_button_released(button_name: String, controller_id: int) -> void:
	if button_name == "trigger_click":
		_on_trigger_released(controller_id)
	elif button_name == "grip_click":
		_on_grip_released(controller_id)
	elif button_name == "stylus_front":
		_stylus_button_release(controller_id, true)
	elif button_name == "stylus_back":
		_stylus_button_release(controller_id, false)


func _on_float_changed(input_name: String, value: float, controller_id: int) -> void:
	if input_name == "trigger":
		if controller_id == CONTROLLER_ID_LEFT:
			_left_trigger_value = value
		else:
			_right_trigger_value = value
	elif input_name == "stylus_tip":
		_stylus_pressure_changed(controller_id, true, value)
	elif input_name == "stylus_side":
		_stylus_pressure_changed(controller_id, false, value)


func _on_vector2_changed(input_name: String, value: Vector2, controller_id: int) -> void:
	if input_name == "primary":
		if controller_id == CONTROLLER_ID_LEFT:
			_left_joystick = value
		else:
			_right_joystick = value


func _on_trigger_pressed(controller_id: int) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		_left_trigger_active = true
	else:
		_right_trigger_active = true

	# Skip when action areas are hidden (main menu state)
	if not left_action_area.visible:
		return

	# Suppress all trigger interactions while a virtual keyboard is open — the
	# keyboard's own SubViewport handles trigger clicks on its key buttons.
	if app_manager.is_keyboard_active():
		return

	# Priority 0: a point grip is dragging on this controller — the trigger toggles
	# orientation lock (freeze the grabbed points' rotation), not an extrude/draw.
	if is_grip_translating(controller_id):
		_toggle_grip_orientation_lock(controller_id)
		return

	# Priority 1: hovered control points — extrude/insert
	var hover_set := _get_hover_set(controller_id)
	if not hover_set.is_empty():
		_begin_extrude_or_insert(controller_id, hover_set)
		return

	# Priority 2: pointing at panel — panel handles its own clicks
	if app_manager.is_pointing_at_panel(controller_id):
		return

	# Priority 2.5: a navigation grip is already active on this controller — the
	# trigger is the yaw-lock modifier (navigation.gd handles it), not a draw.
	if navigation and navigation.is_navigating(controller_id):
		return

	# Priority 3: empty space — begin drawing
	_begin_drawing(controller_id)


func _on_trigger_released(controller_id: int) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		_left_trigger_active = false
	else:
		_right_trigger_active = false

	# Finalize drawing if active
	var is_drawing := _left_drawing if controller_id == CONTROLLER_ID_LEFT else _right_drawing
	if is_drawing:
		_finalize_drawing(controller_id)
		project_manager.autosave()
		return

	# Finalize extrude/insert if active
	var extruding := _left_extruding if controller_id == CONTROLLER_ID_LEFT else _right_extruding
	if not extruding.is_empty():
		var touched_splines: Array[SplineNode] = []
		for entry in extruding:
			var sn := entry["spline"] as SplineNode
			sn.set_point_editing(entry["index"], false, _entry_symmetry_index(entry))
			if not touched_splines.has(sn):
				touched_splines.append(sn)
		_merge_duplicates_on(touched_splines)
		if controller_id == CONTROLLER_ID_LEFT:
			_left_extruding = []
		else:
			_right_extruding = []
		project_manager.autosave()
		return


# --- MX Ink stylus routing (standalone, per-hand) ---

# --- Pressure group (tip / side) ---

## Tip/side pressure changed. Smooths pressure into the width pipeline, updates
## each actuator's gate, and starts/ends the single shared pressure gesture.
func _stylus_pressure_changed(hand: int, is_tip: bool, value: float) -> void:
	if is_tip:
		_stylus_tip_raw[hand] = value
	else:
		_stylus_side_raw[hand] = value

	var raw := maxf(_stylus_tip_raw[hand], _stylus_side_raw[hand])
	_stylus_pressure_sm[hand] = lerpf(_stylus_pressure_sm[hand], raw, SettingsData.STYLUS_WIDTH_SMOOTH)
	if hand == CONTROLLER_ID_LEFT:
		_left_trigger_value = _stylus_pressure_sm[hand]
	else:
		_right_trigger_value = _stylus_pressure_sm[hand]

	_stylus_update_gate(hand, is_tip)

	var down := _stylus_tip_gated[hand] or _stylus_side_gated[hand]
	if down and not _stylus_press_active[hand]:
		_stylus_press_begin(hand)
	elif not down and _stylus_press_active[hand]:
		_stylus_press_end(hand)


func _stylus_update_gate(hand: int, is_tip: bool) -> void:
	var raw: float = _stylus_tip_raw[hand] if is_tip else _stylus_side_raw[hand]
	var gated: Array[bool] = _stylus_tip_gated if is_tip else _stylus_side_gated
	if not gated[hand] and raw >= SettingsData.STYLUS_GATE_ON:
		gated[hand] = true
	elif gated[hand] and raw < SettingsData.STYLUS_GATE_OFF:
		gated[hand] = false


func _stylus_press_begin(hand: int) -> void:
	# First-come exclusion: a crisp button in progress blocks the pressure group.
	if _stylus_owner[hand] == "button":
		return
	_stylus_owner[hand] = "press"
	_stylus_press_active[hand] = true
	match _stylus_context(hand):
		"menu":
			_stylus_press_gesture[hand] = "menu"
			if _stylus_tip_gated[hand]:
				_stylus_ui_click(hand, true)
				_stylus_menu_click[hand] = true
			if _stylus_side_gated[hand]:
				_stylus_ui_grab(hand, true)
				_stylus_menu_grab[hand] = true
		"hover":
			# Grab/move points (grip). Extrude/insert is intentionally not on the stylus.
			_stylus_press_gesture[hand] = "grab"
			_on_grip_pressed(hand)
		_:  # empty
			_stylus_press_gesture[hand] = "draw"
			_on_trigger_pressed(hand)


func _stylus_press_end(hand: int) -> void:
	_stylus_press_active[hand] = false
	match _stylus_press_gesture[hand]:
		"draw":
			_on_trigger_released(hand)
		"grab":
			_on_grip_released(hand)
		"menu":
			if _stylus_menu_click[hand]:
				_stylus_ui_click(hand, false)
			if _stylus_menu_grab[hand]:
				_stylus_ui_grab(hand, false)
			_stylus_menu_click[hand] = false
			_stylus_menu_grab[hand] = false
	_stylus_press_gesture[hand] = ""
	if _stylus_owner[hand] == "press":
		_stylus_owner[hand] = ""


# --- Button group (front / back): quick still tap vs. deferred hold ---

func _stylus_button_press(hand: int, is_front: bool) -> void:
	# First-come exclusion: a pressure gesture in progress blocks the buttons.
	if _stylus_owner[hand] == "press":
		return
	_stylus_owner[hand] = "button"
	var ctx := _stylus_context(hand)
	var now := Time.get_ticks_msec() / 1000.0
	var pos := _controller_node(hand).global_position
	if is_front:
		_stylus_front_time[hand] = now
		_stylus_front_pos[hand] = pos
		_stylus_front_mode[hand] = ctx
		_stylus_front_started[hand] = false
		if ctx == "menu":
			_stylus_ui_click(hand, true)  # front on a menu = click buttons
		# empty / hover: the hold (drag-adjust) starts later, after SettingsData.STYLUS_HOLD_DELAY
	else:
		_stylus_back_time[hand] = now
		_stylus_back_pos[hand] = pos
		_stylus_back_mode[hand] = ctx
		_stylus_back_started[hand] = false
		match ctx:
			"menu":
				_stylus_ui_grab(hand, true)  # back on a menu (or any UI) = move the panel
			"hover":
				_on_delete_pressed(hand)     # immediate delete
			# empty: navigate starts later, after SettingsData.STYLUS_HOLD_DELAY


## Every frame: promote a held crisp button to its hold action once the delay
## passes (so a quick tap never nudges anything), then drive the front drag-adjust.
func _update_stylus_hold(hand: int) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var fm := _stylus_front_mode[hand]
	if fm == "empty" or fm == "hover":
		if not _stylus_front_started[hand]:
			if now - _stylus_front_time[hand] >= SettingsData.STYLUS_HOLD_DELAY:
				_stylus_front_started[hand] = true
				_stylus_adjust_begin(hand, fm)
		else:
			_stylus_adjust_apply(hand)
	if _stylus_back_mode[hand] == "empty" and not _stylus_back_started[hand]:
		if now - _stylus_back_time[hand] >= SettingsData.STYLUS_HOLD_DELAY:
			_stylus_back_started[hand] = true
			if navigation:
				navigation._on_grip_pressed(_controller_node(hand))

	# While back-hold navigation runs, a side press toggles navigation's yaw lock
	# (snap upright + rotate about vertical only, until pressed again).
	_update_stylus_yaw_lock(hand)


## Toggle navigation yaw lock from the stylus side gate on each press (rising
## edge), but only while this hand is actively back-hold navigating. Navigation
## clears the lock itself when the grip ends, so this needn't undo it on stop.
func _update_stylus_yaw_lock(hand: int) -> void:
	if not navigation:
		return
	var navigating := _stylus_back_started[hand] and _stylus_back_mode[hand] == "empty"
	var side_down := navigating and _stylus_side_gated[hand]
	if side_down and not _stylus_yaw_side[hand]:
		navigation.toggle_yaw_lock(_controller_node(hand))
	_stylus_yaw_side[hand] = side_down


func _stylus_button_release(hand: int, is_front: bool) -> void:
	if is_front:
		var mode := _stylus_front_mode[hand]
		_stylus_front_mode[hand] = ""
		match mode:
			"menu":
				_stylus_ui_click(hand, false)
			"empty", "hover":
				if _stylus_front_started[hand]:
					_stylus_adjust_end(hand)
				elif _stylus_still_tap(hand, _stylus_front_pos[hand]) and not is_input_active():
					project_manager.redo()
		_stylus_front_started[hand] = false
	else:
		var mode := _stylus_back_mode[hand]
		_stylus_back_mode[hand] = ""
		match mode:
			"menu":
				_stylus_ui_grab(hand, false)
			"empty":
				if _stylus_back_started[hand]:
					if navigation:
						navigation._on_grip_released(_controller_node(hand))
				elif _stylus_still_tap(hand, _stylus_back_pos[hand]) and not is_input_active():
					project_manager.undo()
			# "hover": delete already fired on press
		_stylus_back_started[hand] = false
	# Release ownership only once both crisp buttons are up.
	if _stylus_front_mode[hand] == "" and _stylus_back_mode[hand] == "" and _stylus_owner[hand] == "button":
		_stylus_owner[hand] = ""


## A tap = released before the hold delay AND without moving the stylus far.
func _stylus_still_tap(hand: int, press_pos: Vector3) -> bool:
	return _controller_node(hand).global_position.distance_to(press_pos) <= SettingsData.STYLUS_TAP_MAX_MOVE


# --- Front-hold drag-adjust (direct displacement -> value, selection locked) ---

func _stylus_adjust_begin(hand: int, ctx: String) -> void:
	_stylus_adjust_origin[hand] = _controller_node(hand).global_position
	var cam: XRCamera3D = app_manager.xr_camera
	_stylus_adjust_right[hand] = cam.global_transform.basis.x if cam else Vector3.RIGHT
	if ctx == "hover":
		_stylus_adjust_mode[hand] = "points"
		_stylus_adjust_is_weight[hand] = current_mode == Mode.WEIGHT
		var pts: Array[Dictionary] = []
		for entry in _canonical_hover_set(_get_hover_set(hand)):
			var sn := entry["spline"] as SplineNode
			var idx: int = entry["index"]
			var start_val: float = sn.data.weights[idx] if current_mode == Mode.WEIGHT else sn.data.sizes[idx]
			pts.append({"spline": sn, "index": idx, "start": start_val})
		_set_adjust_points(hand, pts)
		_stylus_hover_locked[hand] = true  # freeze the selection while dragging
	else:  # empty — resize the active area
		_stylus_adjust_mode[hand] = "size"
		_stylus_adjust_start_radius[hand] = _action_area(hand).radius


func _stylus_adjust_apply(hand: int) -> void:
	var disp := (_controller_node(hand).global_position - _stylus_adjust_origin[hand]).dot(_stylus_adjust_right[hand])
	var travel: float = app_manager.settings.stylus_joystick_range
	var norm := disp / travel if travel > 0.001 else 0.0
	if _stylus_adjust_mode[hand] == "size":
		var r := _stylus_adjust_start_radius[hand] + norm * SettingsData.STYLUS_ADJ_AREA_SPAN
		if snap_size_enabled and snap_size_step > 0.0:
			r = round(r / snap_size_step) * snap_size_step
		_action_area(hand).set_radius(r)
	elif _stylus_adjust_mode[hand] == "points":
		var is_w := _stylus_adjust_is_weight[hand]
		var span := SettingsData.STYLUS_ADJ_WEIGHT_SPAN if is_w else SettingsData.STYLUS_ADJ_SIZE_SPAN
		var pts := _get_adjust_points(hand)
		var first := 0.0
		for i in pts.size():
			var e: Dictionary = pts[i]
			var sn := e["spline"] as SplineNode
			var idx: int = e["index"]
			var target: float = float(e["start"]) + norm * span
			var snapped: float
			if is_w:
				snapped = snap_weight_value(target)
				sn.data.weights[idx] = snapped
			else:
				snapped = snap_size_value(target)
				sn.data.sizes[idx] = snapped
			sn.mark_dirty()
			if i == 0:
				first = snapped
		_joystick_edited = true
		_update_value_label(hand, first)


func _stylus_adjust_end(hand: int) -> void:
	var was_points := _stylus_adjust_mode[hand] == "points"
	_stylus_adjust_mode[hand] = ""
	_stylus_hover_locked[hand] = false
	_set_adjust_points(hand, [])
	if was_points:
		_hide_value_label(hand)
		project_manager.autosave()


func _get_adjust_points(hand: int) -> Array[Dictionary]:
	return _stylus_adjust_points_l if hand == CONTROLLER_ID_LEFT else _stylus_adjust_points_r


func _set_adjust_points(hand: int, pts: Array[Dictionary]) -> void:
	if hand == CONTROLLER_ID_LEFT:
		_stylus_adjust_points_l = pts
	else:
		_stylus_adjust_points_r = pts


func _action_area(hand: int) -> ActionArea:
	return left_action_area if hand == CONTROLLER_ID_LEFT else right_action_area


# --- Stylus UI targeting (menus, popups, keyboards — all XRPanel) ---

func _stylus_ui_click(hand: int, pressed: bool) -> void:
	for p in get_tree().get_nodes_in_group("xr_panels"):
		if p is XRPanel and is_instance_valid(p):
			(p as XRPanel).inject_click(hand, pressed)


func _stylus_ui_grab(hand: int, pressed: bool) -> void:
	for p in get_tree().get_nodes_in_group("xr_panels"):
		if p is XRPanel and is_instance_valid(p):
			(p as XRPanel).inject_grab(hand, pressed)


func _stylus_pointing_at_ui(hand: int) -> bool:
	for p in get_tree().get_nodes_in_group("xr_panels"):
		if p is XRPanel and is_instance_valid(p) and (p as XRPanel).is_controller_pointing(hand):
			return true
	return false


func _stylus_context(hand: int) -> String:
	if _stylus_pointing_at_ui(hand):
		return "menu"
	if not _get_hover_set(hand).is_empty():
		return "hover"
	return "empty"


func _controller_node(hand: int) -> XRController3D:
	return left_controller if hand == CONTROLLER_ID_LEFT else right_controller


## True while a hand is mid-edit, so hover detection is paused and the highlighted
## selection stays frozen: drawing, grip-moving points, extruding, or a stylus
## drag-adjust. Keeps highlights from bleeding onto points the moving area passes.
func _hover_locked(hand: int) -> bool:
	if hand == CONTROLLER_ID_LEFT:
		return _left_drawing or _left_grip_translating or not _left_extruding.is_empty() or _stylus_hover_locked[CONTROLLER_ID_LEFT]
	return _right_drawing or _right_grip_translating or not _right_extruding.is_empty() or _stylus_hover_locked[CONTROLLER_ID_RIGHT]


## Docking (or any hard reset) ends any in-progress stylus gesture cleanly so the
## per-hand state can't get stuck if the stylus is put away mid-action.
func _stylus_reset(hand: int) -> void:
	if _stylus_press_active[hand]:
		_stylus_press_end(hand)
	if _stylus_front_mode[hand] != "":
		_stylus_button_release(hand, true)
	if _stylus_back_mode[hand] != "":
		_stylus_button_release(hand, false)
	_stylus_adjust_mode[hand] = ""
	_stylus_hover_locked[hand] = false
	_set_adjust_points(hand, [])
	_stylus_owner[hand] = ""
	_stylus_tip_raw[hand] = 0.0
	_stylus_side_raw[hand] = 0.0
	_stylus_tip_gated[hand] = false
	_stylus_side_gated[hand] = false
	_stylus_pressure_sm[hand] = 0.0


# --- Grip-based point translation ---

## Returns true if this controller's grip is being used to translate points
## (so navigation.gd should not move the project space).
func is_grip_translating(controller_id: int) -> bool:
	if controller_id == CONTROLLER_ID_LEFT:
		return _left_grip_translating
	else:
		return _right_grip_translating


## Flip orientation lock for an in-progress point grip: on holds the grabbed points
## at their original orientation (no rotation), off resumes wrist-driven rotation.
## The next _update_grip_transform reflects the change; a haptic tap confirms it.
func _toggle_grip_orientation_lock(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	if controller_id == CONTROLLER_ID_LEFT:
		_left_grip_orient_locked = not _left_grip_orient_locked
	else:
		_right_grip_orient_locked = not _right_grip_orient_locked
	Haptics.tap(controller)


func _on_grip_pressed(controller_id: int) -> void:
	# Suppress point-grip while a virtual keyboard is open.
	if app_manager.is_keyboard_active():
		return
	var hover_set := _canonical_hover_set(_get_hover_set(controller_id))
	if hover_set.is_empty():
		return  # No hovered points — let navigation.gd handle the grip

	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller

	# Snapshot controller position and orientation in project-local space
	var grip_visible_pos := project_space.global_transform.affine_inverse() * controller.global_position
	var first_sn := hover_set[0]["spline"] as SplineNode
	var first_symmetry_index := _entry_symmetry_index(hover_set[0])
	var first_basis: Basis = first_sn.get_symmetry_transforms()[first_symmetry_index]
	var grip_local_pos := first_sn.symmetry_to_base(grip_visible_pos, first_symmetry_index)
	var grip_local_basis := _controller_basis_in_base(controller, first_basis)

	# Snapshot all hovered points
	var grabbed: Array[Dictionary] = []
	for entry in hover_set:
		var spline_node := entry["spline"] as SplineNode
		var idx: int = entry["index"]
		grabbed.append({
			"spline": spline_node,
			"index": idx,
			"initial_pos": spline_node.data.points[idx],
			"symmetry_index": _entry_symmetry_index(entry),
		})
		spline_node.set_point_editing(idx, true, _entry_symmetry_index(entry))

	if controller_id == CONTROLLER_ID_LEFT:
		_left_grip_translating = true
		_left_grip_initial_pos = grip_local_pos
		_left_grip_initial_basis = grip_local_basis
		_left_grip_scale = 1.0
		_left_grip_grabbed = grabbed
		_left_grip_orient_locked = false
	else:
		_right_grip_translating = true
		_right_grip_initial_pos = grip_local_pos
		_right_grip_initial_basis = grip_local_basis
		_right_grip_scale = 1.0
		_right_grip_grabbed = grabbed
		_right_grip_orient_locked = false


func _on_grip_released(controller_id: int) -> void:
	var is_translating := _left_grip_translating if controller_id == CONTROLLER_ID_LEFT else _right_grip_translating
	if not is_translating:
		return

	# Clear editing state
	var grabbed := _left_grip_grabbed if controller_id == CONTROLLER_ID_LEFT else _right_grip_grabbed
	var touched_splines: Array[SplineNode] = []
	for entry in grabbed:
		var sn := entry["spline"] as SplineNode
		sn.set_point_editing(entry["index"], false, _entry_symmetry_index(entry))
		if not touched_splines.has(sn):
			touched_splines.append(sn)
	_merge_duplicates_on(touched_splines)

	if controller_id == CONTROLLER_ID_LEFT:
		_left_grip_translating = false
		_left_grip_initial_basis = Basis.IDENTITY
		_left_grip_scale = 1.0
		_left_grip_grabbed = []
		_left_grip_orient_locked = false
	else:
		_right_grip_translating = false
		_right_grip_initial_basis = Basis.IDENTITY
		_right_grip_scale = 1.0
		_right_grip_grabbed = []
		_right_grip_orient_locked = false

	project_manager.autosave()


func _update_grip_transform(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var initial_pos   := _left_grip_initial_pos   if controller_id == CONTROLLER_ID_LEFT else _right_grip_initial_pos
	var initial_basis := _left_grip_initial_basis if controller_id == CONTROLLER_ID_LEFT else _right_grip_initial_basis
	var grip_scale    := _left_grip_scale         if controller_id == CONTROLLER_ID_LEFT else _right_grip_scale
	var grabbed       := _left_grip_grabbed       if controller_id == CONTROLLER_ID_LEFT else _right_grip_grabbed

	if grabbed.is_empty():
		return
	var current_visible_pos := project_space.global_transform.affine_inverse() * controller.global_position
	var first_entry := grabbed[0]
	var first_sn := first_entry["spline"] as SplineNode
	var first_symmetry_index := _entry_symmetry_index(first_entry)
	var first_basis: Basis = first_sn.get_symmetry_transforms()[first_symmetry_index]
	var current_local_pos := first_sn.symmetry_to_base(current_visible_pos, first_symmetry_index)
	var translate_delta := current_local_pos - initial_pos

	# Orientation lock (trigger toggled during the drag): hold the points at their
	# original orientation — translation + scale only, no rotation from the wrist.
	var orient_locked := _left_grip_orient_locked if controller_id == CONTROLLER_ID_LEFT else _right_grip_orient_locked
	var rotation_delta := Basis.IDENTITY
	if not orient_locked:
		var current_local_basis := _controller_basis_in_base(controller, first_basis)
		rotation_delta = current_local_basis * initial_basis.inverse()

	for entry in grabbed:
		var spline_node := entry["spline"] as SplineNode
		var idx: int = entry["index"]
		var original: Vector3 = entry["initial_pos"]
		var offset := original - initial_pos
		spline_node.data.points[idx] = snap_pos(initial_pos + rotation_delta * offset * grip_scale + translate_delta)
		spline_node.mark_dirty()
