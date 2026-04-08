class_name SplineNode
extends Node3D

var data: SplineData
var mesh_edge_count: int = 8

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _dirty: bool = true


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.7, 0.7, 0.7)

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)

	if data:
		rebuild_mesh()


func _process(_delta: float) -> void:
	if _dirty and data:
		rebuild_mesh()
		_dirty = false


func set_data(new_data: SplineData) -> void:
	data = new_data
	_dirty = true


func mark_dirty() -> void:
	_dirty = true


func rebuild_mesh() -> void:
	if not data or data.point_count() < 2:
		if _mesh_instance:
			_mesh_instance.mesh = null
		return

	var polyline := NurbsEval.eval_curve(data)
	var radii := NurbsEval.eval_curve_sizes(data)
	var mesh := TubeMesh.generate(polyline, radii, mesh_edge_count, data.cyclic)
	_mesh_instance.mesh = mesh
