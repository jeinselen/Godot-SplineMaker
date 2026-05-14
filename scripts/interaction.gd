extends Node3D

## Manages hover detection, trigger state, haptic feedback, joystick routing,
## draw mode recording, and realtime mesh preview.

@onready var left_controller: XRController3D = %LeftController
@onready var right_controller: XRController3D = %RightController
@onready var project_space: Node3D = %ProjectSpace
@onready var project_manager = %ProjectManager
@onready var app_manager = %AppManager

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

const HAPTIC_TAP_AMPLITUDE := 0.3
const HAPTIC_TAP_DURATION := 0.05
const HAPTIC_BUZZ_AMPLITUDE := 0.1
const HAPTIC_BUZZ_DURATION := 0.02
const CONTROLLER_ID_LEFT := 0
const CONTROLLER_ID_RIGHT := 1


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
	# --- Priority system ---
	# 1. Hovered control points (highest) — blocks panel interaction entirely
	# 2. Pointing at panel — blocks drawing and project space navigation
	# 3. Empty space (lowest) — drawing, action area resize, project space navigation

	# Always run hover detection first (skip only when drawing or areas hidden)
	if not _left_drawing and left_action_area.visible:
		_update_hover(CONTROLLER_ID_LEFT, left_controller, left_action_area)
	if not _right_drawing and right_action_area.visible:
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
	if left_action_area.visible and not kb_active:
		if left_hovering and not left_busy:
			_update_joystick_edit(CONTROLLER_ID_LEFT, delta)
		elif not left_on_panel and not left_busy:
			left_action_area.update_size(_left_joystick.y, delta)
	if right_action_area.visible and not kb_active:
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
		left_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)
	if _right_trigger_active and (not _right_extruding.is_empty() or _right_drawing):
		right_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)
	if _left_grip_translating:
		left_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)
	if _right_grip_translating:
		right_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)


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
			for i in spline_node.data.point_count():
				var pt := spline_node.data.points[i]
				if area_local_pos.distance_to(pt) <= local_radius:
					new_hover_set.append({"spline": spline_node, "index": i})

	# Diff: unhover points no longer in set
	for entry in prev_hover_set:
		if not _hover_set_contains(new_hover_set, entry):
			(entry["spline"] as SplineNode).set_point_hovered(entry["index"], false, controller_id)

	# Diff: hover new points
	for entry in new_hover_set:
		if not _hover_set_contains(prev_hover_set, entry):
			(entry["spline"] as SplineNode).set_point_hovered(entry["index"], true, controller_id)

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
		ctrl.trigger_haptic_pulse("haptic", 0.0, HAPTIC_TAP_AMPLITUDE, HAPTIC_TAP_DURATION, 0.0)
	if controller_id == CONTROLLER_ID_LEFT:
		_left_was_hovering = is_hovering
	else:
		_right_was_hovering = is_hovering


func _hover_set_contains(hover_set: Array[Dictionary], entry: Dictionary) -> bool:
	for e in hover_set:
		if e["spline"] == entry["spline"] and e["index"] == entry["index"]:
			return true
	return false


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
	var trigger_val := _left_trigger_value if controller_id == CONTROLLER_ID_LEFT else _right_trigger_value
	var trigger_floor := _left_trigger_floor if controller_id == CONTROLLER_ID_LEFT else _right_trigger_floor

	# Remap from [floor, 1.0] to [0.0, 1.0] so full range is usable after click
	var range_size := 1.0 - trigger_floor
	var remapped := clampf((trigger_val - trigger_floor) / range_size, 0.0, 1.0) if range_size > 0.01 else 0.0

	# Power curve for more control at the low end (square gives ~10% size at ~32% travel)
	var curved := remapped * remapped

	var ps_scale := project_space.global_transform.basis.get_scale().x
	var local_radius := action_area.radius / ps_scale if ps_scale > 0.0001 else action_area.radius
	var min_size := local_radius * 0.01
	return lerpf(min_size, local_radius, curved)


func _show_short_draw_warning(_controller_id: int) -> void:
	app_manager.show_popup(
		"Draw longer to create a spline\n(must be larger than the action area)",
		Color(1.0, 0.9, 0.3),
		30.0
	)


# --- Extrude / Insert ---

func _begin_extrude_or_insert(controller_id: int, hover_set: Array[Dictionary]) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var ctrl_local_pos := project_space.global_transform.affine_inverse() * controller.global_position
	ctrl_local_pos = snap_pos(ctrl_local_pos)

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
			var new_pos := ctrl_local_pos if not is_multi else snap_pos(src_pos)
			var new_idx: int
			if idx == 0:
				sn.data.insert_point(0, new_pos, src_size, src_weight)
				new_idx = 0
			else:
				sn.data.add_point(new_pos, src_size, src_weight)
				new_idx = sn.data.point_count() - 1
			sn.mark_dirty()
			sn.set_point_editing(new_idx, true)
			new_points.append({"spline": sn, "index": new_idx, "initial_pos": new_pos})
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
			var new_pos := ctrl_local_pos if not is_multi else snap_pos((sn.data.points[idx] + sn.data.points[next_idx]) * 0.5)
			sn.data.insert_point(next_idx, new_pos, avg_size, avg_weight)
			sn.mark_dirty()
			sn.set_point_editing(next_idx, true)
			new_points.append({"spline": sn, "index": next_idx, "initial_pos": new_pos})

	# Store extrude state
	_extrude_multi[controller_id] = is_multi
	_extrude_scale[controller_id] = 1.0
	if is_multi:
		# Snapshot controller transform for delta-transform (like grip)
		_extrude_initial_pos[controller_id] = ctrl_local_pos
		var ps_inv_basis := project_space.global_transform.basis.inverse()
		_extrude_initial_basis[controller_id] = ps_inv_basis * controller.global_transform.basis

	if controller_id == CONTROLLER_ID_LEFT:
		_left_extruding = new_points
	else:
		_right_extruding = new_points


func _update_extrude(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var extruding := _left_extruding if controller_id == CONTROLLER_ID_LEFT else _right_extruding
	var ctrl_local_pos := project_space.global_transform.affine_inverse() * controller.global_position

	if not _extrude_multi[controller_id]:
		# Single point: snap directly to controller position
		var snapped_pos := snap_pos(ctrl_local_pos)
		for entry in extruding:
			var sn := entry["spline"] as SplineNode
			var idx: int = entry["index"]
			sn.data.points[idx] = snapped_pos
			sn.mark_dirty()
	else:
		# Multi point: delta-transform (translation + rotation + scale)
		var initial_pos := _extrude_initial_pos[controller_id]
		var initial_basis := _extrude_initial_basis[controller_id]
		var ext_scale := _extrude_scale[controller_id]
		var translate_delta := ctrl_local_pos - initial_pos

		var ps_inv_basis := project_space.global_transform.basis.inverse()
		var current_local_basis := ps_inv_basis * controller.global_transform.basis
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

	var hover_set := _get_hover_set(controller_id)
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

	# Clear hover sets before freeing nodes
	_set_hover_set(controller_id, [])

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

	var hover_set := _get_hover_set(controller_id)
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


## Clears hover state before project_manager frees SplineNodes during restore,
## preventing dangling node references in the hover diff loop.
func clear_hover_sets() -> void:
	_left_hover_set = []
	_right_hover_set = []
	_left_was_hovering = false
	_right_was_hovering = false


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
func _merge_duplicates_on(splines: Array) -> void:
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
	elif button_name == "ax_button":
		var hover_set := _get_hover_set(controller_id)
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


func _on_float_changed(input_name: String, value: float, controller_id: int) -> void:
	if input_name == "trigger":
		if controller_id == CONTROLLER_ID_LEFT:
			_left_trigger_value = value
		else:
			_right_trigger_value = value


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

	# Priority 1: hovered control points — extrude/insert
	var hover_set := _get_hover_set(controller_id)
	if not hover_set.is_empty():
		_begin_extrude_or_insert(controller_id, hover_set)
		return

	# Priority 2: pointing at panel — panel handles its own clicks
	if app_manager.is_pointing_at_panel(controller_id):
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
		var touched_splines := {}
		for entry in extruding:
			var sn := entry["spline"] as SplineNode
			sn.set_point_editing(entry["index"], false)
			touched_splines[sn] = true
		_merge_duplicates_on(touched_splines.keys())
		if controller_id == CONTROLLER_ID_LEFT:
			_left_extruding = []
		else:
			_right_extruding = []
		project_manager.autosave()
		return


# --- Grip-based point translation ---

## Returns true if this controller's grip is being used to translate points
## (so navigation.gd should not move the project space).
func is_grip_translating(controller_id: int) -> bool:
	if controller_id == CONTROLLER_ID_LEFT:
		return _left_grip_translating
	else:
		return _right_grip_translating


func _on_grip_pressed(controller_id: int) -> void:
	# Suppress point-grip while a virtual keyboard is open.
	if app_manager.is_keyboard_active():
		return
	var hover_set := _get_hover_set(controller_id)
	if hover_set.is_empty():
		return  # No hovered points — let navigation.gd handle the grip

	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller

	# Snapshot controller position and orientation in project-local space
	var grip_local_pos := project_space.global_transform.affine_inverse() * controller.global_position
	var ps_inv_basis := project_space.global_transform.basis.inverse()
	var grip_local_basis := ps_inv_basis * controller.global_transform.basis

	# Snapshot all hovered points
	var grabbed: Array[Dictionary] = []
	for entry in hover_set:
		var spline_node := entry["spline"] as SplineNode
		var idx: int = entry["index"]
		grabbed.append({
			"spline": spline_node,
			"index": idx,
			"initial_pos": spline_node.data.points[idx],
		})
		spline_node.set_point_editing(idx, true)

	if controller_id == CONTROLLER_ID_LEFT:
		_left_grip_translating = true
		_left_grip_initial_pos = grip_local_pos
		_left_grip_initial_basis = grip_local_basis
		_left_grip_scale = 1.0
		_left_grip_grabbed = grabbed
	else:
		_right_grip_translating = true
		_right_grip_initial_pos = grip_local_pos
		_right_grip_initial_basis = grip_local_basis
		_right_grip_scale = 1.0
		_right_grip_grabbed = grabbed


func _on_grip_released(controller_id: int) -> void:
	var is_translating := _left_grip_translating if controller_id == CONTROLLER_ID_LEFT else _right_grip_translating
	if not is_translating:
		return

	# Clear editing state
	var grabbed := _left_grip_grabbed if controller_id == CONTROLLER_ID_LEFT else _right_grip_grabbed
	var touched_splines := {}
	for entry in grabbed:
		var sn := entry["spline"] as SplineNode
		sn.set_point_editing(entry["index"], false)
		touched_splines[sn] = true
	_merge_duplicates_on(touched_splines.keys())

	if controller_id == CONTROLLER_ID_LEFT:
		_left_grip_translating = false
		_left_grip_initial_basis = Basis.IDENTITY
		_left_grip_scale = 1.0
		_left_grip_grabbed = []
	else:
		_right_grip_translating = false
		_right_grip_initial_basis = Basis.IDENTITY
		_right_grip_scale = 1.0
		_right_grip_grabbed = []

	project_manager.autosave()


func _update_grip_transform(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var initial_pos   := _left_grip_initial_pos   if controller_id == CONTROLLER_ID_LEFT else _right_grip_initial_pos
	var initial_basis := _left_grip_initial_basis if controller_id == CONTROLLER_ID_LEFT else _right_grip_initial_basis
	var grip_scale    := _left_grip_scale         if controller_id == CONTROLLER_ID_LEFT else _right_grip_scale
	var grabbed       := _left_grip_grabbed       if controller_id == CONTROLLER_ID_LEFT else _right_grip_grabbed

	var current_local_pos := project_space.global_transform.affine_inverse() * controller.global_position
	var translate_delta := current_local_pos - initial_pos

	var ps_inv_basis := project_space.global_transform.basis.inverse()
	var current_local_basis := ps_inv_basis * controller.global_transform.basis
	var rotation_delta := current_local_basis * initial_basis.inverse()

	for entry in grabbed:
		var spline_node := entry["spline"] as SplineNode
		var idx: int = entry["index"]
		var original: Vector3 = entry["initial_pos"]
		var offset := original - initial_pos
		spline_node.data.points[idx] = snap_pos(initial_pos + rotation_delta * offset * grip_scale + translate_delta)
		spline_node.mark_dirty()
