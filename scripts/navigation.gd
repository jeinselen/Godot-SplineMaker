extends Node3D

## Grip-based navigation: translate, rotate, and scale the project space.
## Single grip = translate + rotate. Dual grip = translate + rotate + scale.
## Single grip + trigger (same controller) = "yaw lock": snap the project upright
## and constrain it to translation + rotation about the vertical axis only, so the
## user can straighten the view on demand. Menu button resets the view.

@onready var left_controller: XRController3D = %LeftController
@onready var right_controller: XRController3D = %RightController
@onready var project_space: Node3D = %ProjectSpace
@onready var interaction: Node3D = get_parent().get_node("Interaction")
@onready var app_manager: Node = %AppManager

# Grip state
var left_grip_active: bool = false
var right_grip_active: bool = false

# Single-grip initial snapshots
var _single_ctrl_initial: Transform3D
var _single_project_initial: Transform3D

# Dual-grip initial snapshots
var _dual_left_pos_initial: Vector3
var _dual_right_pos_initial: Vector3
var _dual_midpoint_initial: Vector3
var _dual_distance_initial: float
var _dual_basis_initial: Basis
var _dual_project_initial: Transform3D

# Yaw-lock state: non-null = the controller currently holding grip + trigger.
var _yaw_lock_ctrl: XRController3D = null
var _yaw_ctrl_pos_initial: Vector3
var _yaw_ctrl_yaw_initial: float
var _yaw_project_origin_initial: Vector3
var _yaw_project_scale: Vector3
var _yaw_project_yaw_initial: float


func _ready() -> void:
	left_controller.button_pressed.connect(_on_button_pressed.bind(left_controller))
	left_controller.button_released.connect(_on_button_released.bind(left_controller))
	right_controller.button_pressed.connect(_on_button_pressed.bind(right_controller))
	right_controller.button_released.connect(_on_button_released.bind(right_controller))


func _process(_delta: float) -> void:
	if left_grip_active and right_grip_active:
		_update_dual_grip()
	elif left_grip_active:
		_update_active_single(left_controller)
	elif right_grip_active:
		_update_active_single(right_controller)


## Single-grip frame update, yaw-locked or free depending on the trigger modifier.
func _update_active_single(controller: XRController3D) -> void:
	if _yaw_lock_ctrl == controller:
		_update_yaw_lock(controller)
	else:
		_update_single_grip(controller)


# --- Signal handlers ---

func _on_button_pressed(button_name: String, controller: XRController3D) -> void:
	if button_name == "grip_click":
		_on_grip_pressed(controller)
	elif button_name == "trigger_click":
		begin_yaw_lock(controller)
	elif button_name == "menu_button":
		_reset_view()


func _on_button_released(button_name: String, controller: XRController3D) -> void:
	if button_name == "grip_click":
		_on_grip_released(controller)
	elif button_name == "trigger_click":
		end_yaw_lock(controller)


# --- Grip press/release ---

func _on_grip_pressed(controller: XRController3D) -> void:
	var is_left := controller == left_controller

	# Guard against duplicate press events
	if is_left and left_grip_active:
		return
	if not is_left and right_grip_active:
		return

	var controller_id := 0 if is_left else 1

	# If the controller is pointing at or grabbing a panel, let the panel handle it
	if app_manager.is_pointing_at_panel(controller_id) or app_manager.is_panel_grabbed(controller_id) or app_manager.is_any_panel_grabbed():
		return

	# If interaction has hovered points for this controller, let it handle the grip
	if interaction and not interaction._get_hover_set(controller_id).is_empty():
		return

	if is_left:
		left_grip_active = true
	else:
		right_grip_active = true

	if left_grip_active and right_grip_active:
		# Transition to dual-grip: yaw lock (a single-grip modifier) no longer
		# applies. Snapshot both controllers and project space.
		_yaw_lock_ctrl = null
		_begin_dual_grip()
	else:
		# Single-grip: snapshot the active controller and project space
		_begin_single_grip(controller)


func _on_grip_released(controller: XRController3D) -> void:
	var is_left := controller == left_controller

	if is_left:
		left_grip_active = false
	else:
		right_grip_active = false

	# Releasing grip ends any yaw lock this controller was driving.
	if _yaw_lock_ctrl == controller:
		_yaw_lock_ctrl = null

	# If the other grip is still held, transition from dual back to single
	if left_grip_active:
		_begin_single_grip(left_controller)
	elif right_grip_active:
		_begin_single_grip(right_controller)


# --- Single-grip navigation (translate + rotate) ---

func _begin_single_grip(controller: XRController3D) -> void:
	_single_ctrl_initial = controller.global_transform
	_single_project_initial = project_space.global_transform


func _update_single_grip(controller: XRController3D) -> void:
	var delta_transform := controller.global_transform * _single_ctrl_initial.inverse()
	project_space.global_transform = delta_transform * _single_project_initial


# --- Yaw-lock navigation (upright, translate + rotate about vertical only) ---

## Engage yaw lock for `controller` if it is the sole gripping controller. Called
## by the trigger button (Touch) and by the stylus side press during back-hold
## navigation. A no-op otherwise, so callers needn't pre-check.
func begin_yaw_lock(controller: XRController3D) -> void:
	var is_left := controller == left_controller
	var this_grip := left_grip_active if is_left else right_grip_active
	var other_grip := right_grip_active if is_left else left_grip_active
	if not this_grip or other_grip:
		return  # only a single-grip modifier

	_yaw_lock_ctrl = controller
	_yaw_ctrl_pos_initial = controller.global_position
	_yaw_ctrl_yaw_initial = _yaw_of(controller.global_transform.basis)

	var pt := project_space.global_transform
	_yaw_project_origin_initial = pt.origin
	_yaw_project_scale = pt.basis.get_scale()
	_yaw_project_yaw_initial = _yaw_of(pt.basis)


## Release yaw lock for `controller`, resuming free single-grip from the current
## (now-upright) state so there's no jump.
func end_yaw_lock(controller: XRController3D) -> void:
	if _yaw_lock_ctrl != controller:
		return
	_yaw_lock_ctrl = null
	var is_left := controller == left_controller
	var this_grip := left_grip_active if is_left else right_grip_active
	var other_grip := right_grip_active if is_left else left_grip_active
	if this_grip and not other_grip:
		_begin_single_grip(controller)


func _update_yaw_lock(controller: XRController3D) -> void:
	# Yaw delta of the controller since engage, wrapped so continuous motion past
	# the ±180° euler seam stays smooth (a single engage covers up to ±180°).
	var dyaw := wrapf(_yaw_of(controller.global_transform.basis) - _yaw_ctrl_yaw_initial, -PI, PI)
	var dpos := controller.global_position - _yaw_ctrl_pos_initial

	# Rotate the project about a vertical axis through the controller's grab point
	# (so it orbits the hand like the free grip does), then translate 1:1.
	var yaw_rot := Basis(Vector3.UP, dyaw)
	var rel := _yaw_project_origin_initial - _yaw_ctrl_pos_initial
	var new_origin := _yaw_ctrl_pos_initial + yaw_rot * rel + dpos

	# Upright basis: yaw only, preserving the project's scale.
	var basis := Basis(Vector3.UP, _yaw_project_yaw_initial + dyaw).scaled(_yaw_project_scale)
	project_space.global_transform = Transform3D(basis, new_origin)


## Heading (rotation about world up) of a basis, in radians. Orthonormalizes first
## so a scaled project basis still yields a clean angle.
func _yaw_of(basis: Basis) -> float:
	return basis.orthonormalized().get_euler().y


## True while a navigation grip is active on the controller (used by interaction.gd
## to suppress drawing: with a grip held, the trigger is the yaw-lock modifier).
func is_navigating(controller_id: int) -> bool:
	return left_grip_active if controller_id == 0 else right_grip_active


# --- Dual-grip navigation (translate + rotate + scale) ---

func _begin_dual_grip() -> void:
	_dual_left_pos_initial = left_controller.global_position
	_dual_right_pos_initial = right_controller.global_position
	_dual_midpoint_initial = (_dual_left_pos_initial + _dual_right_pos_initial) * 0.5
	_dual_distance_initial = _dual_left_pos_initial.distance_to(_dual_right_pos_initial)
	_dual_basis_initial = _basis_from_two_points(_dual_left_pos_initial, _dual_right_pos_initial)
	_dual_project_initial = project_space.global_transform


func _update_dual_grip() -> void:
	var left_pos := left_controller.global_position
	var right_pos := right_controller.global_position
	var current_midpoint := (left_pos + right_pos) * 0.5
	var current_distance := left_pos.distance_to(right_pos)

	# Scale ratio (closer = smaller, farther = larger)
	var scale_ratio := 1.0
	if _dual_distance_initial > 0.001:
		scale_ratio = clampf(current_distance / _dual_distance_initial, 0.01, 100.0)

	# Rotation delta between the two controller pairs
	var current_basis := _basis_from_two_points(left_pos, right_pos)
	var rotation_delta := current_basis * _dual_basis_initial.inverse()

	# Apply: rotate and scale around the initial midpoint, then translate
	var result := _dual_project_initial

	# Move to initial midpoint as origin
	result.origin -= _dual_midpoint_initial

	# Apply rotation
	result = Transform3D(rotation_delta, Vector3.ZERO) * result

	# Apply uniform scale
	result.origin *= scale_ratio
	result.basis = result.basis.scaled(Vector3.ONE * scale_ratio)

	# Move back and apply translation delta
	result.origin += current_midpoint

	project_space.global_transform = result


## Build an orientation basis from two points (left → right direction).
func _basis_from_two_points(left_pos: Vector3, right_pos: Vector3) -> Basis:
	var dir := (right_pos - left_pos).normalized()
	if dir.length_squared() < 0.0001:
		return Basis.IDENTITY

	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.FORWARD

	var z_axis := dir.cross(up).normalized()
	var y_axis := z_axis.cross(dir).normalized()
	return Basis(dir, y_axis, z_axis)


# --- View reset ---

func _reset_view() -> void:
	# Drop any in-progress grip, then re-present everything (project space and the
	# active panel) directly in front of the user via the single placement path.
	left_grip_active = false
	right_grip_active = false
	_yaw_lock_ctrl = null
	app_manager.recenter_experience()
