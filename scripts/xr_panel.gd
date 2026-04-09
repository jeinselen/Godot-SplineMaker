class_name XRPanel
extends Node3D

## Reusable 3D panel for XR: renders Godot Control UI via SubViewport onto a
## quad mesh, with controller raycasting, input injection, edge-grab repositioning,
## and a visual ray line.

# --- Configuration ---

## SubViewport resolution in pixels. Also determines quad size via pixel_size.
@export var panel_size := Vector2(512, 768)
## Meters per pixel. 0.001 means 1 pixel = 1mm.
@export var pixel_size: float = 0.001
## Whether the panel can be grabbed and repositioned via grip.
@export var grabbable: bool = true

# --- Constants ---

const EDGE_MARGIN := 0.02  # meters — how far from the quad edge the grab zone extends
const HAPTIC_TAP_AMPLITUDE := 0.3
const HAPTIC_TAP_DURATION := 0.05

# --- Internal state ---

var _viewport: SubViewport
var _content_root: Control  # subclasses add UI as children of this
var _quad_instance: MeshInstance3D
var _quad_mesh: QuadMesh
var _quad_material: StandardMaterial3D
var _edge_material: StandardMaterial3D
var _edge_instance: MeshInstance3D

# Ray line visuals (one per controller)
var _ray_mesh: ImmediateMesh
var _ray_instance: MeshInstance3D
var _ray_material: StandardMaterial3D

# Controller references (set via setup())
var _left_controller: XRController3D
var _right_controller: XRController3D
var _left_joystick: Vector2 = Vector2.ZERO
var _right_joystick: Vector2 = Vector2.ZERO

# Pointing state per controller (0 = left, 1 = right)
var _pointing: Array[bool] = [false, false]
var _hit_uv: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO]
var _was_pointing: Array[bool] = [false, false]

# Grab state
var _grabbed: bool = false
var _grab_controller_id: int = -1
var _grab_initial_ctrl_transform: Transform3D
var _grab_initial_panel_transform: Transform3D

# Controller exclusivity — first pointer locks out the second
var _exclusive_controller: int = -1

# Edge overlap state (per controller)
var _edge_overlap: Array[bool] = [false, false]
var _was_edge_overlap: Array[bool] = [false, false]

# Grip state from controllers (tracked locally for grab detection)
var _left_grip_active: bool = false
var _right_grip_active: bool = false

# Mouse button state for proper press/release injection
var _mouse_pressed: Array[bool] = [false, false]


## The Control root inside the SubViewport. Subclasses populate this.
var content_root: Control:
	get:
		return _content_root


func _ready() -> void:
	_create_viewport()
	_create_quad()
	_create_edge_highlight()
	_create_ray_mesh()


## Track bound callables for clean disconnection.
var _connections: Array[Dictionary] = []  # [{signal: Signal, callable: Callable}]


## Must be called after adding to the scene tree, to provide controller references.
func setup(left_ctrl: XRController3D, right_ctrl: XRController3D) -> void:
	_left_controller = left_ctrl
	_right_controller = right_ctrl

	# Connect grip signals for grab detection
	_safe_connect(_left_controller.button_pressed, _on_controller_button_pressed.bind(0))
	_safe_connect(_left_controller.button_released, _on_controller_button_released.bind(0))
	_safe_connect(_right_controller.button_pressed, _on_controller_button_pressed.bind(1))
	_safe_connect(_right_controller.button_released, _on_controller_button_released.bind(1))

	# Connect joystick signals for scroll
	_safe_connect(_left_controller.input_vector2_changed, _on_joystick_changed.bind(0))
	_safe_connect(_right_controller.input_vector2_changed, _on_joystick_changed.bind(1))

	# Connect trigger for click injection
	_safe_connect(_left_controller.button_pressed, _on_trigger_for_click.bind(0))
	_safe_connect(_left_controller.button_released, _on_trigger_release_for_click.bind(0))
	_safe_connect(_right_controller.button_pressed, _on_trigger_for_click.bind(1))
	_safe_connect(_right_controller.button_released, _on_trigger_release_for_click.bind(1))


func _safe_connect(sig: Signal, callable: Callable) -> void:
	sig.connect(callable)
	_connections.append({"signal": sig, "callable": callable})


func _exit_tree() -> void:
	for conn in _connections:
		var sig: Signal = conn["signal"]
		var callable: Callable = conn["callable"]
		if sig.is_connected(callable):
			sig.disconnect(callable)
	_connections.clear()


func _process(_delta: float) -> void:
	if not _left_controller or not _right_controller:
		return

	# Update grab transform
	if _grabbed:
		_update_grab()

	# Release exclusivity if the exclusive controller is no longer pointing or grabbing
	if _exclusive_controller >= 0:
		if not _pointing[_exclusive_controller] and not (_grabbed and _grab_controller_id == _exclusive_controller):
			_exclusive_controller = -1

	# Raycast both controllers
	_update_raycast(0, _left_controller)
	_update_raycast(1, _right_controller)

	# Assign exclusivity — first pointer wins
	if _exclusive_controller < 0:
		if _pointing[0] and not _pointing[1]:
			_exclusive_controller = 0
		elif _pointing[1] and not _pointing[0]:
			_exclusive_controller = 1
		elif _pointing[0] and _pointing[1]:
			_exclusive_controller = 0  # tie-break: left wins

	# Update edge overlap detection
	_update_edge_overlap(0, _left_controller)
	_update_edge_overlap(1, _right_controller)

	# Update edge highlight
	var any_edge := _edge_overlap[0] or _edge_overlap[1]
	_edge_instance.visible = any_edge and not _grabbed

	# Draw ray lines
	_draw_rays()

	# Inject joystick scroll for pointing controllers
	_update_scroll(0)
	_update_scroll(1)


# --- Public API ---

## Returns true if the given controller is pointing at this panel.
func is_controller_pointing(controller_id: int) -> bool:
	if controller_id < 0 or controller_id > 1:
		return false
	return _pointing[controller_id]


## Returns true if the panel is currently being grabbed.
func is_grabbed() -> bool:
	return _grabbed


## Returns true if the given controller is grabbing this panel.
func is_grabbed_by(controller_id: int) -> bool:
	return _grabbed and _grab_controller_id == controller_id


## Position the panel relative to a camera, offset to the given side.
func reset_position(camera: XRCamera3D, side: String = "left") -> void:
	var cam_t := camera.global_transform

	# Use world-aligned horizontal forward (ignore head pitch/roll)
	var cam_forward := -cam_t.basis.z
	var horizontal_forward := Vector3(cam_forward.x, 0.0, cam_forward.z).normalized()
	var horizontal_right := Vector3.UP.cross(horizontal_forward).normalized()

	# Place 0.8m in front, 0.35m to the side, 0.05m below eye level
	var side_offset := -0.35 if side == "left" else 0.35
	var target_pos := cam_t.origin + horizontal_forward * 0.8 + horizontal_right * side_offset + Vector3.UP * -0.05

	# Face the camera: look_at points -Z at target, but QuadMesh faces +Z,
	# so we look away from the camera to make the front face visible.
	var away_target := target_pos + horizontal_forward
	global_transform = Transform3D.IDENTITY
	global_position = target_pos
	look_at(away_target, Vector3.UP)


# --- Viewport & Quad creation ---

func _create_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(int(panel_size.x), int(panel_size.y))
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.gui_disable_input = false
	_viewport.handle_input_locally = true
	add_child(_viewport)

	_content_root = Control.new()
	_content_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_viewport.add_child(_content_root)


func _create_quad() -> void:
	_quad_mesh = QuadMesh.new()
	_quad_mesh.size = Vector2(panel_size.x * pixel_size, panel_size.y * pixel_size)

	_quad_material = StandardMaterial3D.new()
	_quad_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_quad_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_quad_material.albedo_color = Color(1, 1, 1, 1)
	_quad_material.cull_mode = BaseMaterial3D.CULL_BACK

	_quad_instance = MeshInstance3D.new()
	_quad_instance.mesh = _quad_mesh
	_quad_instance.material_override = _quad_material
	add_child(_quad_instance)

	# Texture will be set after viewport renders its first frame
	_quad_material.albedo_texture = _viewport.get_texture()


func _create_edge_highlight() -> void:
	# A slightly larger quad behind the main one, with highlight color, shown on edge overlap
	var edge_mesh := QuadMesh.new()
	var margin := EDGE_MARGIN * 2.0
	edge_mesh.size = Vector2(panel_size.x * pixel_size + margin, panel_size.y * pixel_size + margin)

	_edge_material = StandardMaterial3D.new()
	_edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_edge_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_edge_material.albedo_color = Color(0.3, 0.8, 1.0, 0.3)
	_edge_material.no_depth_test = true

	_edge_instance = MeshInstance3D.new()
	_edge_instance.mesh = edge_mesh
	_edge_instance.material_override = _edge_material
	_edge_instance.position = Vector3(0, 0, 0.001)  # slightly behind
	_edge_instance.visible = false
	add_child(_edge_instance)


func _create_ray_mesh() -> void:
	_ray_material = StandardMaterial3D.new()
	_ray_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ray_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ray_material.albedo_color = Color(0.3, 0.8, 1.0, 0.4)
	_ray_material.no_depth_test = true

	_ray_mesh = ImmediateMesh.new()
	_ray_instance = MeshInstance3D.new()
	_ray_instance.mesh = _ray_mesh
	# Ray lines are in global space — add as top-level child
	add_child(_ray_instance)
	_ray_instance.top_level = true


# --- Raycast ---

func _update_raycast(controller_id: int, controller: XRController3D) -> void:
	var ray_origin := controller.global_position
	var ray_dir := -controller.global_transform.basis.z  # aim direction

	# Panel plane: normal = panel's local +Z in global space, point = panel origin
	var panel_normal := global_transform.basis.z.normalized()
	var panel_origin := global_position

	# Ray-plane intersection
	var denom := panel_normal.dot(ray_dir)
	if absf(denom) < 0.00001:
		_set_pointing(controller_id, false)
		return

	var t := panel_normal.dot(panel_origin - ray_origin) / denom
	if t < 0.0:
		_set_pointing(controller_id, false)
		return

	var hit_global := ray_origin + ray_dir * t

	# Convert to panel local space
	var hit_local := global_transform.affine_inverse() * hit_global

	# Check if within quad bounds
	var half_w := panel_size.x * pixel_size * 0.5
	var half_h := panel_size.y * pixel_size * 0.5

	if absf(hit_local.x) > half_w or absf(hit_local.y) > half_h:
		_set_pointing(controller_id, false)
		return

	# Convert local position to UV (0,0 = top-left, 1,1 = bottom-right)
	# Local X: -half_w to +half_w → U: 0 to 1
	# Local Y: +half_h to -half_h → V: 0 to 1 (Y is flipped: up in 3D = top of UI)
	var u := (hit_local.x + half_w) / (half_w * 2.0)
	var v := (-hit_local.y + half_h) / (half_h * 2.0)
	_hit_uv[controller_id] = Vector2(u, v)

	# Suppress input for non-exclusive controller
	if _exclusive_controller >= 0 and _exclusive_controller != controller_id:
		_set_pointing(controller_id, false)
		return

	_set_pointing(controller_id, true)

	# Inject mouse motion event
	var vp_pos := Vector2(u * panel_size.x, v * panel_size.y)
	var motion := InputEventMouseMotion.new()
	motion.position = vp_pos
	motion.global_position = vp_pos
	_viewport.push_input(motion)


func _set_pointing(controller_id: int, pointing: bool) -> void:
	_was_pointing[controller_id] = _pointing[controller_id]
	_pointing[controller_id] = pointing

	# Haptic tap on first intersection
	if pointing and not _was_pointing[controller_id]:
		var ctrl := _left_controller if controller_id == 0 else _right_controller
		ctrl.trigger_haptic_pulse("haptic", 0.0, HAPTIC_TAP_AMPLITUDE, HAPTIC_TAP_DURATION, 0.0)

	# If no longer pointing, release any held mouse button
	if not pointing and _mouse_pressed[controller_id]:
		_inject_mouse_button(controller_id, false)
		_mouse_pressed[controller_id] = false


# --- Click injection ---

func _on_trigger_for_click(button_name: String, controller_id: int) -> void:
	if button_name != "trigger_click":
		return
	if _exclusive_controller >= 0 and _exclusive_controller != controller_id:
		return
	if not _pointing[controller_id]:
		return
	_inject_mouse_button(controller_id, true)
	_mouse_pressed[controller_id] = true


func _on_trigger_release_for_click(button_name: String, controller_id: int) -> void:
	if button_name != "trigger_click":
		return
	if not _mouse_pressed[controller_id]:
		return
	_inject_mouse_button(controller_id, false)
	_mouse_pressed[controller_id] = false


func _inject_mouse_button(controller_id: int, pressed: bool) -> void:
	var uv := _hit_uv[controller_id]
	var vp_pos := Vector2(uv.x * panel_size.x, uv.y * panel_size.y)

	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = vp_pos
	event.global_position = vp_pos
	_viewport.push_input(event)


# --- Scroll ---

func _on_joystick_changed(input_name: String, value: Vector2, controller_id: int) -> void:
	if input_name == "primary":
		if controller_id == 0:
			_left_joystick = value
		else:
			_right_joystick = value


func _update_scroll(controller_id: int) -> void:
	if not _pointing[controller_id]:
		return

	var joy := _left_joystick if controller_id == 0 else _right_joystick
	if absf(joy.y) < 0.3:
		return

	var uv := _hit_uv[controller_id]
	var vp_pos := Vector2(uv.x * panel_size.x, uv.y * panel_size.y)

	# Scroll direction: joystick up (positive Y) = scroll up
	var button := MOUSE_BUTTON_WHEEL_UP if joy.y > 0.0 else MOUSE_BUTTON_WHEEL_DOWN

	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = true
	event.position = vp_pos
	event.global_position = vp_pos
	event.factor = absf(joy.y)
	_viewport.push_input(event)

	# Immediate release
	var release := InputEventMouseButton.new()
	release.button_index = button
	release.pressed = false
	release.position = vp_pos
	release.global_position = vp_pos
	_viewport.push_input(release)


# --- Edge overlap & grab ---

func _update_edge_overlap(controller_id: int, controller: XRController3D) -> void:
	if _grabbed:
		return

	var ctrl_pos := controller.global_position
	var local_pos := global_transform.affine_inverse() * ctrl_pos

	var half_w := panel_size.x * pixel_size * 0.5
	var half_h := panel_size.y * pixel_size * 0.5

	# Check if within extended edge region but near the panel plane
	var in_depth := absf(local_pos.z) < EDGE_MARGIN * 3.0
	var in_x := absf(local_pos.x) < half_w + EDGE_MARGIN
	var in_y := absf(local_pos.y) < half_h + EDGE_MARGIN
	var in_inner_x := absf(local_pos.x) < half_w - EDGE_MARGIN
	var in_inner_y := absf(local_pos.y) < half_h - EDGE_MARGIN

	# Edge region = inside extended bounds but NOT deep inside the panel body
	var in_edge := in_depth and in_x and in_y and not (in_inner_x and in_inner_y)

	_was_edge_overlap[controller_id] = _edge_overlap[controller_id]
	_edge_overlap[controller_id] = in_edge

	# Haptic tap on first edge overlap
	if in_edge and not _was_edge_overlap[controller_id]:
		controller.trigger_haptic_pulse("haptic", 0.0, HAPTIC_TAP_AMPLITUDE, HAPTIC_TAP_DURATION, 0.0)


func _on_controller_button_pressed(button_name: String, controller_id: int) -> void:
	if button_name != "grip_click":
		return
	if controller_id == 0:
		_left_grip_active = true
	else:
		_right_grip_active = true

	if not grabbable or _grabbed:
		return
	if not _edge_overlap[controller_id] and not _pointing[controller_id]:
		return

	# Begin grab
	_grabbed = true
	_grab_controller_id = controller_id
	var ctrl := _left_controller if controller_id == 0 else _right_controller
	_grab_initial_ctrl_transform = ctrl.global_transform
	_grab_initial_panel_transform = global_transform


func _on_controller_button_released(button_name: String, controller_id: int) -> void:
	if button_name != "grip_click":
		return
	if controller_id == 0:
		_left_grip_active = false
	else:
		_right_grip_active = false

	if _grabbed and _grab_controller_id == controller_id:
		_grabbed = false
		_grab_controller_id = -1


func _update_grab() -> void:
	var ctrl := _left_controller if _grab_controller_id == 0 else _right_controller
	var delta_transform := ctrl.global_transform * _grab_initial_ctrl_transform.inverse()

	# Apply 1:1 translation
	global_transform = delta_transform * _grab_initial_panel_transform

	# Lock to yaw only: project facing direction onto horizontal plane
	var pos := global_position
	var face_dir := global_transform.basis.z
	var horizontal_face := Vector3(face_dir.x, 0.0, face_dir.z).normalized()
	var look_target := pos - horizontal_face
	global_transform = Transform3D.IDENTITY
	global_position = pos
	look_at(look_target, Vector3.UP)


# --- Ray line drawing ---

func _draw_rays() -> void:
	_ray_mesh.clear_surfaces()

	for i in 2:
		if not _pointing[i]:
			continue
		var ctrl := _left_controller if i == 0 else _right_controller
		var ray_origin := ctrl.global_position
		var uv := _hit_uv[i]

		# Reconstruct hit point in global space
		var local_hit := Vector3(
			(uv.x - 0.5) * panel_size.x * pixel_size,
			-(uv.y - 0.5) * panel_size.y * pixel_size,
			0.0
		)
		var hit_global := global_transform * local_hit

		_ray_mesh.surface_begin(Mesh.PRIMITIVE_LINES, _ray_material)
		_ray_mesh.surface_add_vertex(_ray_instance.to_local(ray_origin))
		_ray_mesh.surface_add_vertex(_ray_instance.to_local(hit_global))
		_ray_mesh.surface_end()
