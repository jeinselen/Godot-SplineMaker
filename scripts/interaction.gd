extends Node3D

## Manages hover detection, trigger state, haptic feedback, joystick routing,
## draw mode recording, and realtime mesh preview.

@onready var left_controller: XRController3D = %LeftController
@onready var right_controller: XRController3D = %RightController
@onready var project_space: Node3D = %ProjectSpace

var left_action_area: ActionArea
var right_action_area: ActionArea

# Mode state
enum Mode { DRAW, MOVE, EXTRUDE, SIZE, WEIGHT }
var current_mode: Mode = Mode.DRAW
var curve_accuracy: float = 0.5  # 0.0 = smoothest, 1.0 = tightest fit

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
var _left_draw_samples: PackedVector3Array = PackedVector3Array()
var _right_draw_samples: PackedVector3Array = PackedVector3Array()
var _left_draw_sizes: PackedFloat32Array = PackedFloat32Array()
var _right_draw_sizes: PackedFloat32Array = PackedFloat32Array()
var _left_preview_node: SplineNode = null
var _right_preview_node: SplineNode = null

# Warning popup state
var _short_draw_warned: bool = false

const HAPTIC_TAP_AMPLITUDE := 0.3
const HAPTIC_TAP_DURATION := 0.05
const HAPTIC_BUZZ_AMPLITUDE := 0.1
const HAPTIC_BUZZ_DURATION := 0.02
const CONTROLLER_ID_LEFT := 0
const CONTROLLER_ID_RIGHT := 1
const DRAW_SAMPLE_MIN_DISTANCE := 0.002


func _ready() -> void:
	# Create action areas as children of controllers
	left_action_area = ActionArea.new()
	left_action_area.name = "ActionArea"
	left_controller.add_child(left_action_area)

	right_action_area = ActionArea.new()
	right_action_area.name = "ActionArea"
	right_controller.add_child(right_action_area)

	# Connect input signals
	left_controller.button_pressed.connect(_on_button_pressed.bind(CONTROLLER_ID_LEFT))
	left_controller.button_released.connect(_on_button_released.bind(CONTROLLER_ID_LEFT))
	left_controller.input_float_changed.connect(_on_float_changed.bind(CONTROLLER_ID_LEFT))
	left_controller.input_vector2_changed.connect(_on_vector2_changed.bind(CONTROLLER_ID_LEFT))

	right_controller.button_pressed.connect(_on_button_pressed.bind(CONTROLLER_ID_RIGHT))
	right_controller.button_released.connect(_on_button_released.bind(CONTROLLER_ID_RIGHT))
	right_controller.input_float_changed.connect(_on_float_changed.bind(CONTROLLER_ID_RIGHT))
	right_controller.input_vector2_changed.connect(_on_vector2_changed.bind(CONTROLLER_ID_RIGHT))


func _process(delta: float) -> void:
	# Update action area sizes from joystick Y (forward = larger, back = smaller)
	left_action_area.update_size(_left_joystick.y, delta)
	right_action_area.update_size(_right_joystick.y, delta)

	# Run hover detection (skip for controllers that are currently drawing)
	if not _left_drawing:
		_update_hover(CONTROLLER_ID_LEFT, left_controller, left_action_area)
	if not _right_drawing:
		_update_hover(CONTROLLER_ID_RIGHT, right_controller, right_action_area)

	# Draw mode: record samples and update preview
	if _left_drawing:
		_record_draw_sample(CONTROLLER_ID_LEFT)
		_update_draw_preview(CONTROLLER_ID_LEFT)
	if _right_drawing:
		_record_draw_sample(CONTROLLER_ID_RIGHT)
		_update_draw_preview(CONTROLLER_ID_RIGHT)

	# Haptic buzz while trigger held and editing
	if _left_trigger_active and (not _left_hover_set.is_empty() or _left_drawing):
		left_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)
	if _right_trigger_active and (not _right_hover_set.is_empty() or _right_drawing):
		right_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)


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

	_set_hover_set(controller_id, new_hover_set)

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


func _hover_set_contains(set: Array[Dictionary], entry: Dictionary) -> bool:
	for e in set:
		if e["spline"] == entry["spline"] and e["index"] == entry["index"]:
			return true
	return false


func _get_hover_set(controller_id: int) -> Array[Dictionary]:
	return _left_hover_set if controller_id == CONTROLLER_ID_LEFT else _right_hover_set


func _set_hover_set(controller_id: int, set: Array[Dictionary]) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		_left_hover_set = set
	else:
		_right_hover_set = set


# --- Draw mode ---

func _begin_drawing(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var action_area := left_action_area if controller_id == CONTROLLER_ID_LEFT else right_action_area

	# Get controller position in project-local space
	var pos := project_space.global_transform.affine_inverse() * controller.global_position
	var trigger_val := _left_trigger_value if controller_id == CONTROLLER_ID_LEFT else _right_trigger_value
	var size_val := lerpf(0.01, action_area.radius, clampf(trigger_val, 0.0, 1.0))

	var samples := PackedVector3Array([pos])
	var sizes := PackedFloat32Array([size_val])

	# Create preview spline node
	var preview := SplineNode.new()
	preview.name = "DrawPreview"
	project_space.add_child(preview)

	if controller_id == CONTROLLER_ID_LEFT:
		_left_drawing = true
		_left_draw_samples = samples
		_left_draw_sizes = sizes
		_left_preview_node = preview
	else:
		_right_drawing = true
		_right_draw_samples = samples
		_right_draw_sizes = sizes
		_right_preview_node = preview


func _record_draw_sample(controller_id: int) -> void:
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var action_area := left_action_area if controller_id == CONTROLLER_ID_LEFT else right_action_area
	var samples := _left_draw_samples if controller_id == CONTROLLER_ID_LEFT else _right_draw_samples
	var sizes := _left_draw_sizes if controller_id == CONTROLLER_ID_LEFT else _right_draw_sizes

	var pos := project_space.global_transform.affine_inverse() * controller.global_position

	# Only add sample if moved enough distance (avoids flooding with duplicate points)
	if samples.size() > 0 and pos.distance_to(samples[samples.size() - 1]) < DRAW_SAMPLE_MIN_DISTANCE:
		return

	var trigger_val := _left_trigger_value if controller_id == CONTROLLER_ID_LEFT else _right_trigger_value
	# Scale size by project space scale so the radius is in local units
	var ps_scale := project_space.global_transform.basis.get_scale().x
	var local_radius := action_area.radius / ps_scale if ps_scale > 0.0001 else action_area.radius
	var size_val := lerpf(0.01, local_radius, clampf(trigger_val, 0.0, 1.0))

	samples.append(pos)
	sizes.append(size_val)

	# Store back (PackedArrays are value types in GDScript)
	if controller_id == CONTROLLER_ID_LEFT:
		_left_draw_samples = samples
		_left_draw_sizes = sizes
	else:
		_right_draw_samples = samples
		_right_draw_sizes = sizes


func _update_draw_preview(controller_id: int) -> void:
	var samples := _left_draw_samples if controller_id == CONTROLLER_ID_LEFT else _right_draw_samples
	var sizes := _left_draw_sizes if controller_id == CONTROLLER_ID_LEFT else _right_draw_sizes
	var preview := _left_preview_node if controller_id == CONTROLLER_ID_LEFT else _right_preview_node

	if not preview or samples.size() < 2:
		return

	# Fit the current samples and update the preview mesh
	var data := CurveFitting.fit(samples, sizes, curve_accuracy)
	preview.set_data(data)


func _finalize_drawing(controller_id: int) -> void:
	var samples := _left_draw_samples if controller_id == CONTROLLER_ID_LEFT else _right_draw_samples
	var sizes := _left_draw_sizes if controller_id == CONTROLLER_ID_LEFT else _right_draw_sizes
	var preview := _left_preview_node if controller_id == CONTROLLER_ID_LEFT else _right_preview_node
	var action_area := left_action_area if controller_id == CONTROLLER_ID_LEFT else right_action_area

	# Check minimum viable spline length
	var path_length := CurveFitting._polyline_length(samples)
	var ps_scale := project_space.global_transform.basis.get_scale().x
	var min_length := (action_area.radius * 2.0) / ps_scale if ps_scale > 0.0001 else action_area.radius * 2.0

	if path_length < min_length or samples.size() < 2:
		# Too short — discard
		if preview:
			preview.queue_free()
		if not _short_draw_warned:
			_short_draw_warned = true
			_show_short_draw_warning(controller_id)
	else:
		# Finalize: fit the complete path and replace preview with final spline
		if preview:
			var data := CurveFitting.fit(samples, sizes, curve_accuracy)
			preview.set_data(data)
			preview.set_active(true)
			preview.name = "Spline"

	# Clear draw state
	if controller_id == CONTROLLER_ID_LEFT:
		_left_drawing = false
		_left_draw_samples = PackedVector3Array()
		_left_draw_sizes = PackedFloat32Array()
		_left_preview_node = null
	else:
		_right_drawing = false
		_right_draw_samples = PackedVector3Array()
		_right_draw_sizes = PackedFloat32Array()
		_right_preview_node = null


func _cancel_drawing(controller_id: int) -> void:
	var preview := _left_preview_node if controller_id == CONTROLLER_ID_LEFT else _right_preview_node
	if preview:
		preview.queue_free()

	if controller_id == CONTROLLER_ID_LEFT:
		_left_drawing = false
		_left_draw_samples = PackedVector3Array()
		_left_draw_sizes = PackedFloat32Array()
		_left_preview_node = null
	else:
		_right_drawing = false
		_right_draw_samples = PackedVector3Array()
		_right_draw_sizes = PackedFloat32Array()
		_right_preview_node = null


func _show_short_draw_warning(controller_id: int) -> void:
	# Simple warning using a 3D label at the controller position
	var controller := left_controller if controller_id == CONTROLLER_ID_LEFT else right_controller
	var warning := Label3D.new()
	warning.text = "Draw longer to create a spline\n(must be larger than the action area)"
	warning.font_size = 32
	warning.pixel_size = 0.001
	warning.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	warning.modulate = Color(1.0, 0.9, 0.3)
	warning.global_position = controller.global_position + Vector3(0, 0.1, 0)
	add_child(warning)

	# Auto-dismiss after 5 seconds (short for testing; spec says 30s but that's for the full panel version)
	var timer := get_tree().create_timer(5.0)
	timer.timeout.connect(func() -> void:
		if is_instance_valid(warning):
			warning.queue_free()
	)


# --- Input signal handlers ---

func _on_button_pressed(button_name: String, controller_id: int) -> void:
	if button_name == "trigger_click":
		_on_trigger_pressed(controller_id)


func _on_button_released(button_name: String, controller_id: int) -> void:
	if button_name == "trigger_click":
		_on_trigger_released(controller_id)


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

	var hover_set := _get_hover_set(controller_id)

	if current_mode == Mode.DRAW and hover_set.is_empty():
		# No points hovered — begin drawing a new spline
		_begin_drawing(controller_id)
	else:
		# Mark hovered points as editing
		for entry in hover_set:
			(entry["spline"] as SplineNode).set_point_editing(entry["index"], true)


func _on_trigger_released(controller_id: int) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		_left_trigger_active = false
	else:
		_right_trigger_active = false

	# Finalize drawing if active
	var is_drawing := _left_drawing if controller_id == CONTROLLER_ID_LEFT else _right_drawing
	if is_drawing:
		_finalize_drawing(controller_id)
		return

	# Clear editing state on hovered points
	var hover_set := _get_hover_set(controller_id)
	for entry in hover_set:
		(entry["spline"] as SplineNode).set_point_editing(entry["index"], false)
