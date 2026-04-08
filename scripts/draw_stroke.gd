class_name DrawStroke
extends RefCounted

## Progressive stroke builder inspired by Procreate's smoothing system.
##
## As each raw position arrives, it's smoothed (cursor lags behind the controller),
## and control points are placed based on curvature and distance thresholds.
## The SplineNode is updated in real-time — what you see while drawing IS the
## final result. No refit on trigger release.
##
## Future: "smoothing" slider controls follow_speed (how much the cursor lags).
## More smoothing = smoother path = naturally fewer control points.

## How quickly the smoothed cursor follows the raw input.
## 0.0 = maximum lag/smoothing, 1.0 = no smoothing (raw input).
var smoothing: float = 0.5

## The spline node being built (lives in the scene tree under ProjectSpace).
var spline_node: SplineNode = null

## The spline data being built incrementally.
var data: SplineData = SplineData.new()

# Internal state
var _smoothed_pos: Vector3 = Vector3.ZERO
var _smoothed_size: float = 0.1
var _prev_smoothed_pos: Vector3 = Vector3.ZERO
var _last_direction: Vector3 = Vector3.ZERO
var _cumulative_angle: float = 0.0
var _cumulative_dist: float = 0.0
var _initialized: bool = false
var _total_length: float = 0.0

# Thresholds for placing new control points
const ANGLE_THRESHOLD := 0.25        # ~14 degrees of cumulative direction change
const DISTANCE_THRESHOLD := 0.08     # 8cm max straight-line spacing
const MIN_FRAME_DIST := 0.0002       # ignore sub-0.2mm cursor movement


## Call once to set up the spline node in the scene.
func begin(start_pos: Vector3, start_size: float, parent: Node3D) -> void:
	_smoothed_pos = start_pos
	_smoothed_size = start_size
	_prev_smoothed_pos = start_pos
	_initialized = true

	data = SplineData.new()
	data.order_u = 4
	# First committed point + trailing cursor point
	data.add_point(start_pos, start_size)
	data.add_point(start_pos, start_size)

	spline_node = SplineNode.new()
	spline_node.name = "DrawPreview"
	parent.add_child(spline_node)
	spline_node.set_data(data)


## Call each frame with the raw controller position and trigger-derived size.
## Returns true if the spline data changed (mesh should rebuild).
func update(raw_pos: Vector3, raw_size: float) -> bool:
	if not _initialized:
		return false

	# Progressive smoothing: cursor follows raw position with adjustable lag
	var follow_speed := lerpf(0.08, 0.7, smoothing)
	_smoothed_pos = _smoothed_pos.lerp(raw_pos, follow_speed)
	_smoothed_size = lerpf(_smoothed_size, raw_size, follow_speed)

	# How far did the smoothed cursor move this frame?
	var frame_delta := _smoothed_pos - _prev_smoothed_pos
	var frame_dist := frame_delta.length()
	_prev_smoothed_pos = _smoothed_pos

	if frame_dist < MIN_FRAME_DIST:
		return false

	_total_length += frame_dist

	# Track direction change
	var direction := frame_delta / frame_dist
	if _last_direction.length_squared() > 0.5:
		var dot := clampf(_last_direction.dot(direction), -1.0, 1.0)
		_cumulative_angle += acos(dot)
	_last_direction = direction

	_cumulative_dist += frame_dist

	# Always update the trailing cursor point (last point in the data)
	var last_idx := data.point_count() - 1
	data.points[last_idx] = _smoothed_pos
	data.sizes[last_idx] = _smoothed_size

	# Check if we should commit the current position and start a new segment
	if _cumulative_angle >= ANGLE_THRESHOLD or _cumulative_dist >= DISTANCE_THRESHOLD:
		# Commit: the trailing point becomes a real control point
		# Add a new trailing cursor point after it
		data.add_point(_smoothed_pos, _smoothed_size)
		data.order_u = mini(4, data.point_count())
		_cumulative_angle = 0.0
		_cumulative_dist = 0.0

	# Update the spline node with modified data
	if spline_node:
		spline_node.mark_dirty()

	return true


## Call on trigger release. Finalizes the stroke.
## Returns the total drawn path length (for minimum-length checking).
func finalize() -> float:
	if not _initialized:
		return 0.0

	# Remove the trailing cursor point if it's too close to the previous committed point
	var n := data.point_count()
	if n >= 2:
		var second_last := data.points[n - 2]
		var last := data.points[n - 1]
		if second_last.distance_to(last) < 0.005:
			# Remove the trailing duplicate
			data.points = data.points.slice(0, n - 1)
			data.sizes = data.sizes.slice(0, n - 1)
			data.weights = data.weights.slice(0, n - 1)

	data.order_u = mini(4, data.point_count())

	if spline_node:
		spline_node.set_data(data)

	return _total_length


## Cancel the stroke, removing the preview from the scene.
func cancel() -> void:
	if spline_node:
		spline_node.queue_free()
		spline_node = null
