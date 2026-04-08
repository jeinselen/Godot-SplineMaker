extends Node3D

## Manages hover detection, trigger state, haptic feedback, and joystick routing
## between controllers and spline control points.

@onready var left_controller: XRController3D = %LeftController
@onready var right_controller: XRController3D = %RightController
@onready var project_space: Node3D = %ProjectSpace

var left_action_area: ActionArea
var right_action_area: ActionArea

# Per-controller state
var _left_trigger_active: bool = false
var _right_trigger_active: bool = false
var _left_joystick: Vector2 = Vector2.ZERO
var _right_joystick: Vector2 = Vector2.ZERO

# Track which points each controller is hovering: controller_id -> Array of {spline: SplineNode, index: int}
var _left_hover_set: Array[Dictionary] = []
var _right_hover_set: Array[Dictionary] = []

# Haptic state: track whether we already fired the entry tap
var _left_was_hovering: bool = false
var _right_was_hovering: bool = false

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
	# Update action area sizes from joystick X
	left_action_area.update_size(_left_joystick.x, delta)
	right_action_area.update_size(_right_joystick.x, delta)

	# Run hover detection
	_update_hover(CONTROLLER_ID_LEFT, left_controller, left_action_area)
	_update_hover(CONTROLLER_ID_RIGHT, right_controller, right_action_area)

	# Haptic buzz while trigger held and editing
	if _left_trigger_active and not _left_hover_set.is_empty():
		left_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)
	if _right_trigger_active and not _right_hover_set.is_empty():
		right_controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_BUZZ_AMPLITUDE, HAPTIC_BUZZ_DURATION, 0.0)


func _update_hover(controller_id: int, controller: XRController3D, action_area: ActionArea) -> void:
	var area_global_pos := controller.global_position
	var area_radius := action_area.radius

	# Transform the action area position into project space local coordinates
	var area_local_pos := project_space.global_transform.affine_inverse() * area_global_pos
	# Scale the radius by the inverse of the project space scale
	var ps_scale := project_space.global_transform.basis.get_scale().x
	var local_radius := area_radius / ps_scale if ps_scale > 0.0001 else area_radius

	var prev_hover_set := _get_hover_set(controller_id)
	var new_hover_set: Array[Dictionary] = []

	# Check all spline nodes under project space
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

	# Store new set
	_set_hover_set(controller_id, new_hover_set)

	# Lock action area resize when points are hovered
	action_area.resize_locked = not new_hover_set.is_empty()

	# Highlight action area sphere
	action_area.set_highlight(not new_hover_set.is_empty())

	# Haptic tap on first hover entry
	var was_hovering := _left_was_hovering if controller_id == CONTROLLER_ID_LEFT else _right_was_hovering
	var is_hovering := not new_hover_set.is_empty()
	if is_hovering and not was_hovering:
		controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_TAP_AMPLITUDE, HAPTIC_TAP_DURATION, 0.0)
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


# --- Input signal handlers ---

func _on_button_pressed(button_name: String, controller_id: int) -> void:
	if button_name == "trigger_click":
		_on_trigger_pressed(controller_id)


func _on_button_released(button_name: String, controller_id: int) -> void:
	if button_name == "trigger_click":
		_on_trigger_released(controller_id)


func _on_float_changed(_name: String, _value: float, _controller_id: int) -> void:
	pass


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

	# Mark hovered points as editing (scale back to default, keep color)
	var hover_set := _get_hover_set(controller_id)
	for entry in hover_set:
		(entry["spline"] as SplineNode).set_point_editing(entry["index"], true)


func _on_trigger_released(controller_id: int) -> void:
	if controller_id == CONTROLLER_ID_LEFT:
		_left_trigger_active = false
	else:
		_right_trigger_active = false

	# Clear editing state on all points
	var hover_set := _get_hover_set(controller_id)
	for entry in hover_set:
		(entry["spline"] as SplineNode).set_point_editing(entry["index"], false)
