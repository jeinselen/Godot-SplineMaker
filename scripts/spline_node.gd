class_name SplineNode
extends Node3D

const CUBE_SIZE := 0.012
const CUBE_HOVER_SCALE := 1.5
const COLOR_ACTIVE := Color(0.3, 0.8, 1.0)
const COLOR_NEUTRAL := Color(0.5, 0.5, 0.5)
const COLOR_HOVER := Color(1.0, 0.9, 0.3)
const XRAY_ALPHA := 0.2

var data: SplineData
var mesh_edge_count: int = 8
var spline_resolution: int = 8
var is_active: bool = false     # True for finalized splines (not in-progress previews)
var is_selected: bool = false   # True for the currently selected spline (visual highlight)

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _dirty: bool = true

# Control point visualization
var _cp_container: Node3D
var _cp_meshes: Array[MeshInstance3D] = []
var _cp_line_mesh_instance: MeshInstance3D
var _cp_cube_mesh: BoxMesh
var _cp_mat_normal: StandardMaterial3D
var _cp_mat_hover: StandardMaterial3D
var _cp_line_mat: StandardMaterial3D

# Per-point hover state: tracks which controllers are hovering each point
# Key = point index, Value = array of controller identifiers
var _hovered_points: Dictionary = {}
# Points being actively edited (trigger held)
var _editing_points: Dictionary = {}


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.7, 0.7, 0.7)

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)

	# Control point container (child of this node, so aligned to project space)
	_cp_container = Node3D.new()
	_cp_container.name = "ControlPoints"
	add_child(_cp_container)

	# Shared cube mesh for control points
	_cp_cube_mesh = BoxMesh.new()
	_cp_cube_mesh.size = Vector3.ONE * CUBE_SIZE

	# Materials for control point states
	_cp_mat_normal = StandardMaterial3D.new()
	_cp_mat_normal.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cp_mat_normal.albedo_color = COLOR_NEUTRAL
	_cp_mat_normal.next_pass = _make_xray_material(COLOR_NEUTRAL)

	_cp_mat_hover = StandardMaterial3D.new()
	_cp_mat_hover.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cp_mat_hover.albedo_color = COLOR_HOVER
	_cp_mat_hover.next_pass = _make_xray_material(COLOR_HOVER)

	# Line material
	_cp_line_mat = StandardMaterial3D.new()
	_cp_line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_cp_line_mat.albedo_color = COLOR_NEUTRAL
	_cp_line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_cp_line_mat.albedo_color.a = 0.5
	_cp_line_mat.next_pass = _make_xray_material(COLOR_NEUTRAL, 0.15)

	# Line mesh instance
	_cp_line_mesh_instance = MeshInstance3D.new()
	_cp_line_mesh_instance.name = "ControlPointLines"
	_cp_container.add_child(_cp_line_mesh_instance)

	if data:
		rebuild_mesh()


func _process(_delta: float) -> void:
	if _dirty and data:
		rebuild_mesh()
		_rebuild_control_points()
		_dirty = false


func set_data(new_data: SplineData) -> void:
	data = new_data
	_dirty = true


func mark_dirty() -> void:
	_dirty = true


func set_active(active: bool) -> void:
	is_active = active


func set_selected(selected: bool) -> void:
	is_selected = selected
	_update_control_point_colors()


func set_point_hovered(index: int, hovered: bool, controller_id: int) -> void:
	if hovered:
		if index not in _hovered_points:
			_hovered_points[index] = []
		var arr: Array = _hovered_points[index]
		if controller_id not in arr:
			arr.append(controller_id)
	else:
		if index in _hovered_points:
			var arr: Array = _hovered_points[index]
			arr.erase(controller_id)
			if arr.is_empty():
				_hovered_points.erase(index)
	_update_point_visual(index)


func set_point_editing(index: int, editing: bool) -> void:
	if editing:
		_editing_points[index] = true
	else:
		_editing_points.erase(index)
	_update_point_visual(index)


func is_point_hovered(index: int) -> bool:
	return index in _hovered_points


func rebuild_mesh() -> void:
	if not data or data.point_count() < 2:
		if _mesh_instance:
			_mesh_instance.mesh = null
		return

	var polyline := NurbsEval.eval_curve(data, spline_resolution)
	var radii := NurbsEval.eval_curve_sizes(data, spline_resolution)
	var mesh := TubeMesh.generate(polyline, radii, mesh_edge_count, data.cyclic)
	_mesh_instance.mesh = mesh


func _rebuild_control_points() -> void:
	if not data:
		return

	var n := data.point_count()

	# Resize cube mesh array
	while _cp_meshes.size() < n:
		var mi := MeshInstance3D.new()
		mi.mesh = _cp_cube_mesh
		mi.material_override = _cp_mat_normal
		_cp_container.add_child(mi)
		_cp_meshes.append(mi)

	while _cp_meshes.size() > n:
		var mi := _cp_meshes.pop_back() as MeshInstance3D
		mi.queue_free()

	# Update positions and visuals
	for i in n:
		_cp_meshes[i].position = data.points[i]
		_update_point_visual(i)

	# Rebuild connecting lines
	_rebuild_lines()

	# Clean up stale hover/editing state
	var keys_to_remove: Array = []
	for key in _hovered_points:
		if key >= n:
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_hovered_points.erase(key)

	keys_to_remove.clear()
	for key in _editing_points:
		if key >= n:
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_editing_points.erase(key)


func _rebuild_lines() -> void:
	var n := data.point_count()
	if n < 2:
		_cp_line_mesh_instance.mesh = null
		return

	var im := ImmediateMesh.new()
	var line_color := COLOR_ACTIVE if is_selected else COLOR_NEUTRAL
	_cp_line_mat.albedo_color = Color(line_color.r, line_color.g, line_color.b, 0.5)
	(_cp_line_mat.next_pass as StandardMaterial3D).albedo_color = Color(line_color.r, line_color.g, line_color.b, 0.15)

	im.surface_begin(Mesh.PRIMITIVE_LINES, _cp_line_mat)
	for i in n - 1:
		im.surface_add_vertex(data.points[i])
		im.surface_add_vertex(data.points[i + 1])
	if data.cyclic and n > 2:
		im.surface_add_vertex(data.points[n - 1])
		im.surface_add_vertex(data.points[0])
	im.surface_end()

	_cp_line_mesh_instance.mesh = im


func _update_point_visual(index: int) -> void:
	if index < 0 or index >= _cp_meshes.size():
		return

	var mi := _cp_meshes[index]
	var hovered := index in _hovered_points
	var editing := index in _editing_points

	# Color
	if hovered or editing:
		mi.material_override = _cp_mat_hover
	else:
		mi.material_override = _cp_mat_normal

	# Scale: hover = enlarged, editing = back to default but keep color
	if hovered and not editing:
		mi.scale = Vector3.ONE * CUBE_HOVER_SCALE
	else:
		mi.scale = Vector3.ONE


func _update_control_point_colors() -> void:
	# Update the normal material color based on active state
	var base_color := COLOR_ACTIVE if is_selected else COLOR_NEUTRAL
	_cp_mat_normal.albedo_color = base_color
	(_cp_mat_normal.next_pass as StandardMaterial3D).albedo_color = Color(base_color.r, base_color.g, base_color.b, XRAY_ALPHA)
	# Rebuild lines to update their color
	if data and data.point_count() >= 2:
		_rebuild_lines()
	# Re-apply visuals on all points
	for i in _cp_meshes.size():
		_update_point_visual(i)


static func _make_xray_material(color: Color, alpha: float = XRAY_ALPHA) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	return mat
