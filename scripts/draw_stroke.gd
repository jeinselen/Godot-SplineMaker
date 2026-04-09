class_name DrawStroke
extends RefCounted

## Progressive stroke builder with Procreate-style smoothing.
##
## The smoothed cursor lags behind the raw controller input. Control points
## are committed when cumulative direction change or distance thresholds are
## met. The main NURBS mesh only rebuilds on new point commits.
## A lightweight tip mesh connects the last committed point to the cursor,
## updated every frame for real-time feedback.

## Controls both cursor lag and point density.
## 0.0 = minimal smoothing, more points. 1.0 = heavy smoothing, fewer points.
var smoothing: float = 0.5

## Number of vertices around each cross-section ring for preview mesh.
var mesh_edge_count: int = 8
## Samples per NURBS segment for preview mesh.
var spline_resolution: int = 8

## The spline node being built (lives under ProjectSpace).
var spline_node: SplineNode = null

## The spline data being built incrementally.
var data: SplineData = SplineData.new()

# Tip preview: simple tube from last committed point to cursor
var _tip_mesh_instance: MeshInstance3D = null
var _tip_material: StandardMaterial3D = null
var _parent: Node3D = null

# Internal state
var _smoothed_pos: Vector3 = Vector3.ZERO
var _smoothed_size: float = 0.1
var _prev_smoothed_pos: Vector3 = Vector3.ZERO
var _last_direction: Vector3 = Vector3.ZERO
var _cumulative_angle: float = 0.0
var _cumulative_dist: float = 0.0
var _initialized: bool = false
var _total_length: float = 0.0


func begin(start_pos: Vector3, start_size: float, parent: Node3D) -> void:
	_smoothed_pos = start_pos
	_smoothed_size = start_size
	_prev_smoothed_pos = start_pos
	_initialized = true
	_parent = parent

	data = SplineData.new()
	data.order_u = 4
	data.add_point(start_pos, start_size)

	spline_node = SplineNode.new()
	spline_node.name = "DrawPreview"
	spline_node.mesh_edge_count = mesh_edge_count
	spline_node.spline_resolution = spline_resolution
	parent.add_child(spline_node)

	# Tip mesh for the leading edge
	_tip_material = StandardMaterial3D.new()
	_tip_material.albedo_color = Color(0.7, 0.7, 0.7)
	_tip_mesh_instance = MeshInstance3D.new()
	_tip_mesh_instance.name = "DrawTip"
	_tip_mesh_instance.material_override = _tip_material
	parent.add_child(_tip_mesh_instance)


## Call each frame with the raw controller position and trigger-derived size.
func update(raw_pos: Vector3, raw_size: float) -> void:
	if not _initialized:
		return

	# Progressive smoothing: cursor follows raw input with lag
	var follow_speed := lerpf(0.12, 0.7, 1.0 - smoothing)
	_smoothed_pos = _smoothed_pos.lerp(raw_pos, follow_speed)
	_smoothed_size = lerpf(_smoothed_size, raw_size, follow_speed)

	# How far did the smoothed cursor move this frame?
	var frame_delta := _smoothed_pos - _prev_smoothed_pos
	var frame_dist := frame_delta.length()
	_prev_smoothed_pos = _smoothed_pos

	if frame_dist < 0.0002:
		_update_tip()
		return

	_total_length += frame_dist
	_cumulative_dist += frame_dist

	# Track direction change
	var direction := frame_delta / frame_dist
	if _last_direction.length_squared() > 0.5:
		var dot := clampf(_last_direction.dot(direction), -1.0, 1.0)
		_cumulative_angle += acos(dot)
	_last_direction = direction

	# Thresholds scale with smoothing
	var angle_threshold := lerpf(0.5, 1.3, smoothing)
	var distance_threshold := lerpf(0.1, 0.4, smoothing)

	if _cumulative_angle >= angle_threshold or _cumulative_dist >= distance_threshold:
		_commit_point(_smoothed_pos, _smoothed_size)

	# Always update the tip mesh to follow the cursor
	_update_tip()


func _commit_point(pos: Vector3, size: float) -> void:
	data.add_point(pos, size)
	data.order_u = mini(4, data.point_count())
	_cumulative_angle = 0.0
	_cumulative_dist = 0.0

	# Rebuild the main NURBS mesh only on commit
	if data.point_count() >= 2 and spline_node:
		spline_node.set_data(data)


## Update the lightweight tip tube from the last committed point to the cursor.
func _update_tip() -> void:
	if not _tip_mesh_instance:
		return

	var n := data.point_count()
	if n < 1:
		return

	var last_committed := data.points[n - 1]
	var last_size: float = data.sizes[n - 1]

	# Only show tip if cursor has moved away from last committed point
	if _smoothed_pos.distance_to(last_committed) < 0.002:
		_tip_mesh_instance.mesh = null
		return

	# Build a short polyline for the tip: last committed point → cursor
	# Add a midpoint for smoother curvature transition
	var mid := last_committed.lerp(_smoothed_pos, 0.5)
	var mid_size := lerpf(last_size, _smoothed_size, 0.5)

	var tip_points := PackedVector3Array([last_committed, mid, _smoothed_pos])
	var tip_sizes := PackedFloat32Array([last_size, mid_size, _smoothed_size])

	_tip_mesh_instance.mesh = TubeMesh.generate(tip_points, tip_sizes, mesh_edge_count, false)


## Call on trigger release. Returns total smoothed path length.
func finalize() -> float:
	if not _initialized:
		return 0.0

	# Commit the final cursor position as the endpoint
	var n := data.point_count()
	if n >= 1:
		var last := data.points[n - 1]
		if _smoothed_pos.distance_to(last) > 0.003:
			data.add_point(_smoothed_pos, _smoothed_size)

	data.order_u = mini(4, data.point_count())

	if spline_node and data.point_count() >= 2:
		spline_node.set_data(data)

	# Remove the tip mesh
	if _tip_mesh_instance:
		_tip_mesh_instance.queue_free()
		_tip_mesh_instance = null

	return _total_length


## Cancel the stroke, removing everything from the scene.
func cancel() -> void:
	if spline_node:
		spline_node.queue_free()
		spline_node = null
	if _tip_mesh_instance:
		_tip_mesh_instance.queue_free()
		_tip_mesh_instance = null
