class_name ActionArea
extends Node3D

## Transparent sphere at the controller tip representing the interaction area.
## Joystick X axis resizes it. Resize is locked when points are inside the area.

const SIZE_MIN := 0.01
const SIZE_MAX := 1.0
const SIZE_DEFAULT := 0.1
const RESIZE_SPEED := 0.1

var radius: float = SIZE_DEFAULT
var resize_locked: bool = false

## Snap step applied to the radius (0 = no snap). Set by interaction.gd from
## the size-snap project setting.
var snap_step: float = 0.0

var _mesh_instance: MeshInstance3D
var _sphere_mesh: SphereMesh
var _material: StandardMaterial3D

# Unsnapped running radius; tracks continuous joystick input so snapping
# doesn't lock the value at one increment.
var _raw_radius: float = SIZE_DEFAULT
var _resizing: bool = false


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.albedo_color = Color(0.5, 0.8, 1.0, 0.1)
	_material.no_depth_test = true

	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radial_segments = 16
	_sphere_mesh.rings = 8
	_apply_radius()

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = _sphere_mesh
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)


func update_size(joystick_y: float, delta: float) -> void:
	if resize_locked:
		_resizing = false
		return
	if absf(joystick_y) < 0.1:
		_resizing = false
		return

	# Seed the unsnapped accumulator on the first frame of a new edit session.
	if not _resizing:
		_raw_radius = radius
		_resizing = true

	_raw_radius = clampf(_raw_radius + joystick_y * RESIZE_SPEED * delta, SIZE_MIN, SIZE_MAX)

	var new_radius := _raw_radius
	if snap_step > 0.0:
		new_radius = clampf(round(_raw_radius / snap_step) * snap_step, SIZE_MIN, SIZE_MAX)

	radius = new_radius
	_apply_radius()


func set_highlight(highlighted: bool) -> void:
	if highlighted:
		_material.albedo_color = Color(1.0, 0.9, 0.3, 0.15)
	else:
		_material.albedo_color = Color(0.5, 0.8, 1.0, 0.1)


func _apply_radius() -> void:
	_sphere_mesh.radius = radius
	_sphere_mesh.height = radius * 2.0
