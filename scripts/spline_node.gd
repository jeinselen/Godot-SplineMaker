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
var _mesh_instances: Array[MeshInstance3D] = []
var _material: StandardMaterial3D
var _dirty: bool = true
var _symmetry_transforms: Array[Basis] = [Basis.IDENTITY]

# Control point visualization
var _cp_container: Node3D
var _cp_meshes: Array[Array] = []
var _cp_line_mesh_instances: Array[MeshInstance3D] = []
var _cp_cube_mesh: BoxMesh
var _cp_mat_normal: StandardMaterial3D
var _cp_mat_hover: StandardMaterial3D
var _cp_line_mat: StandardMaterial3D

# Per-visible-point hover state. Key = "symmetry_index:point_index",
# value = array of controller identifiers.
var _hovered_points: Dictionary = {}
# Points being actively edited (trigger held)
var _editing_points: Dictionary = {}


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.7, 0.7, 0.7)

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _material
	add_child(_mesh_instance)
	_mesh_instances.append(_mesh_instance)

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

	_ensure_symmetry_visual_count()

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


func set_symmetry_transforms(transforms: Array[Basis]) -> void:
	_symmetry_transforms = transforms.duplicate()
	if _symmetry_transforms.is_empty():
		_symmetry_transforms = [Basis.IDENTITY]
	if is_inside_tree():
		_ensure_symmetry_visual_count()
	mark_dirty()


func get_symmetry_transforms() -> Array[Basis]:
	return _symmetry_transforms.duplicate()


func set_active(active: bool) -> void:
	is_active = active


func set_selected(selected: bool) -> void:
	is_selected = selected
	_update_control_point_colors()


func set_point_hovered(index: int, hovered: bool, controller_id: int, symmetry_index: int = 0) -> void:
	var visual_key := _visual_key(index, symmetry_index)
	if hovered:
		if visual_key not in _hovered_points:
			_hovered_points[visual_key] = []
		var arr: Array = _hovered_points[visual_key]
		if controller_id not in arr:
			arr.append(controller_id)
	else:
		if visual_key in _hovered_points:
			var arr: Array = _hovered_points[visual_key]
			arr.erase(controller_id)
			if arr.is_empty():
				_hovered_points.erase(visual_key)
	_update_point_visual(index, symmetry_index)


func set_point_editing(index: int, editing: bool, symmetry_index: int = 0) -> void:
	var visual_key := _visual_key(index, symmetry_index)
	if editing:
		_editing_points[visual_key] = true
	else:
		_editing_points.erase(visual_key)
	_update_point_visual(index, symmetry_index)


func is_point_hovered(index: int) -> bool:
	for symmetry_index in _symmetry_transforms.size():
		if _visual_key(index, symmetry_index) in _hovered_points:
			return true
	return false


func get_visible_point_entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not data:
		return result
	for symmetry_index in _symmetry_transforms.size():
		var xf := _symmetry_transforms[symmetry_index]
		for i in data.point_count():
			result.append({
				"index": i,
				"symmetry_index": symmetry_index,
				"position": xf * data.points[i],
			})
	return result


func symmetry_to_base(pos: Vector3, symmetry_index: int) -> Vector3:
	if symmetry_index < 0 or symmetry_index >= _symmetry_transforms.size():
		return pos
	return _symmetry_transforms[symmetry_index].inverse() * pos


func base_to_symmetry(pos: Vector3, symmetry_index: int) -> Vector3:
	if symmetry_index < 0 or symmetry_index >= _symmetry_transforms.size():
		return pos
	return _symmetry_transforms[symmetry_index] * pos


func materialized_spline_data() -> Array[SplineData]:
	var result: Array[SplineData] = []
	if not data:
		return result
	for xf in _symmetry_transforms:
		var sd := SplineData.new()
		sd.order_u = data.order_u
		sd.cyclic = data.cyclic
		for i in data.point_count():
			sd.add_point(xf * data.points[i], data.sizes[i], data.weights[i])
		result.append(sd)
	return result


func rebuild_mesh() -> void:
	_ensure_symmetry_visual_count()
	if not data or data.point_count() < 2:
		for mi in _mesh_instances:
			mi.mesh = null
		return

	var polyline := NurbsEval.eval_curve(data, spline_resolution)
	var radii := NurbsEval.eval_curve_sizes(data, spline_resolution)
	for symmetry_index in _symmetry_transforms.size():
		var xf := _symmetry_transforms[symmetry_index]
		var transformed := PackedVector3Array()
		transformed.resize(polyline.size())
		for i in polyline.size():
			transformed[i] = xf * polyline[i]
		_mesh_instances[symmetry_index].mesh = TubeMesh.generate(transformed, radii, mesh_edge_count, data.cyclic)


func _rebuild_control_points() -> void:
	if not data:
		return

	var n := data.point_count()
	var symmetry_count := _symmetry_transforms.size()
	_ensure_symmetry_visual_count()

	for symmetry_index in symmetry_count:
		var meshes := _cp_meshes[symmetry_index]

		# Resize cube mesh array
		while meshes.size() < n:
			var mi := MeshInstance3D.new()
			mi.mesh = _cp_cube_mesh
			mi.material_override = _cp_mat_normal
			_cp_container.add_child(mi)
			meshes.append(mi)

		while meshes.size() > n:
			var mi := meshes.pop_back() as MeshInstance3D
			mi.queue_free()

		# Update positions and visuals
		var xf := _symmetry_transforms[symmetry_index]
		for i in n:
			meshes[i].position = xf * data.points[i]
			_update_point_visual(i, symmetry_index)

	# Rebuild connecting lines
	_rebuild_lines()

	# Clean up stale hover/editing state
	var keys_to_remove: Array = []
	for key in _hovered_points:
		if _point_index_from_visual_key(str(key)) >= n:
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_hovered_points.erase(key)

	keys_to_remove.clear()
	for key in _editing_points:
		if _point_index_from_visual_key(str(key)) >= n:
			keys_to_remove.append(key)
	for key in keys_to_remove:
		_editing_points.erase(key)


func _rebuild_lines() -> void:
	var n := data.point_count()
	if n < 2:
		for line_mi in _cp_line_mesh_instances:
			line_mi.mesh = null
		return

	var line_color := COLOR_ACTIVE if is_selected else COLOR_NEUTRAL
	_cp_line_mat.albedo_color = Color(line_color.r, line_color.g, line_color.b, 0.5)
	(_cp_line_mat.next_pass as StandardMaterial3D).albedo_color = Color(line_color.r, line_color.g, line_color.b, 0.15)

	for symmetry_index in _symmetry_transforms.size():
		var im := ImmediateMesh.new()
		var xf := _symmetry_transforms[symmetry_index]
		im.surface_begin(Mesh.PRIMITIVE_LINES, _cp_line_mat)
		for i in n - 1:
			im.surface_add_vertex(xf * data.points[i])
			im.surface_add_vertex(xf * data.points[i + 1])
		if data.cyclic and n > 2:
			im.surface_add_vertex(xf * data.points[n - 1])
			im.surface_add_vertex(xf * data.points[0])
		im.surface_end()

		_cp_line_mesh_instances[symmetry_index].mesh = im


func _update_point_visual(index: int, symmetry_index: int = 0) -> void:
	if symmetry_index < 0 or symmetry_index >= _cp_meshes.size():
		return
	var meshes := _cp_meshes[symmetry_index]
	if index < 0 or index >= meshes.size():
		return

	var mi := meshes[index] as MeshInstance3D
	var visual_key := _visual_key(index, symmetry_index)
	var hovered := visual_key in _hovered_points
	var editing := visual_key in _editing_points

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
	for symmetry_index in _cp_meshes.size():
		for i in (_cp_meshes[symmetry_index] as Array).size():
			_update_point_visual(i, symmetry_index)


func _ensure_symmetry_visual_count() -> void:
	if _cp_container == null:
		return
	while _mesh_instances.size() < _symmetry_transforms.size():
		var mi := MeshInstance3D.new()
		mi.material_override = _material
		add_child(mi)
		_mesh_instances.append(mi)
	while _mesh_instances.size() > _symmetry_transforms.size():
		var mi := _mesh_instances.pop_back() as MeshInstance3D
		mi.queue_free()

	while _cp_line_mesh_instances.size() < _symmetry_transforms.size():
		var line_mi := MeshInstance3D.new()
		line_mi.name = "ControlPointLines"
		_cp_container.add_child(line_mi)
		_cp_line_mesh_instances.append(line_mi)
	while _cp_line_mesh_instances.size() > _symmetry_transforms.size():
		var line_mi := _cp_line_mesh_instances.pop_back() as MeshInstance3D
		line_mi.queue_free()

	while _cp_meshes.size() < _symmetry_transforms.size():
		_cp_meshes.append([])
	while _cp_meshes.size() > _symmetry_transforms.size():
		var meshes := _cp_meshes.pop_back() as Array
		for mi in meshes:
			if is_instance_valid(mi):
				(mi as MeshInstance3D).queue_free()


static func _visual_key(index: int, symmetry_index: int) -> String:
	return "%d:%d" % [symmetry_index, index]


static func _point_index_from_visual_key(key: String) -> int:
	var parts := key.split(":")
	if parts.size() < 2:
		return -1
	return int(parts[1])


static func _make_xray_material(color: Color, alpha: float = XRAY_ALPHA) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	return mat
