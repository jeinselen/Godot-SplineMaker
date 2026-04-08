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

var _mesh_instance: MeshInstance3D
var _sphere_mesh: SphereMesh
var _material: StandardMaterial3D


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
		return
	if absf(joystick_y) < 0.1:
		return

	radius += joystick_y * RESIZE_SPEED * delta
	radius = clampf(radius, SIZE_MIN, SIZE_MAX)
	_apply_radius()


func set_highlight(highlighted: bool) -> void:
	if highlighted:
		_material.albedo_color = Color(1.0, 0.9, 0.3, 0.15)
	else:
		_material.albedo_color = Color(0.5, 0.8, 1.0, 0.1)


func _apply_radius() -> void:
	_sphere_mesh.radius = radius
	_sphere_mesh.height = radius * 2.0
