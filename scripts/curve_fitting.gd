class_name CurveFitting
extends RefCounted

## Converts a dense hand-drawn polyline into sparse NURBS control points.
##
## Pipeline:
## 1. Low-pass filter (bidirectional EMA) to remove jitter
## 2. Curvature-based point placement (not RDP) to preserve path topology
##    - Places points where cumulative angle change or arc length exceed thresholds
##    - Naturally handles spirals, loops, and paths crossing themselves


## Fit a complete set of raw samples into a SplineData.
## accuracy: 0.0 (fewest points, smoothest) to 1.0 (most points, tightest fit)
static func fit(
	positions: PackedVector3Array,
	sizes: PackedFloat32Array,
	accuracy: float
) -> SplineData:
	if positions.size() < 2:
		var d := SplineData.new()
		for i in positions.size():
			var s: float = sizes[i] if i < sizes.size() else 0.1
			d.add_point(positions[i], s)
		return d

	# 1. Smooth the input to remove hand jitter
	var smooth_alpha := lerpf(0.15, 0.6, accuracy)
	var smoothed := _smooth_ema(positions, smooth_alpha)
	var smoothed_sizes := _smooth_ema_scalar(sizes, smooth_alpha)

	# 2. Curvature-based simplification
	var indices := _curvature_simplify(smoothed, accuracy)

	if indices.size() < 2:
		indices = PackedInt32Array([0, positions.size() - 1])

	# 3. Extract simplified points and sizes
	var data := SplineData.new()
	data.order_u = mini(4, indices.size())
	for idx in indices:
		data.add_point(smoothed[idx], smoothed_sizes[idx])

	return data


## Smooth raw samples for use as a direct preview polyline (no fitting).
static func smooth_for_preview(
	positions: PackedVector3Array,
	sizes: PackedFloat32Array,
	accuracy: float
) -> Array:
	if positions.size() < 2:
		return [positions.duplicate(), sizes.duplicate()]
	var smooth_alpha := lerpf(0.15, 0.6, accuracy)
	var smoothed := _smooth_ema(positions, smooth_alpha)
	var smoothed_sizes := _smooth_ema_scalar(sizes, smooth_alpha)
	return [smoothed, smoothed_sizes]


## Walk along the polyline, placing a control point whenever:
## - Cumulative angle change since last placed point exceeds an angle threshold, OR
## - Arc length since last placed point exceeds a distance threshold
## Always includes first and last points.
static func _curvature_simplify(points: PackedVector3Array, accuracy: float) -> PackedInt32Array:
	var n := points.size()
	if n <= 3:
		var result := PackedInt32Array()
		for i in n:
			result.append(i)
		return result

	# Thresholds controlled by accuracy:
	# Low accuracy = large thresholds = fewer points
	# High accuracy = small thresholds = more points
	var angle_threshold := lerpf(0.8, 0.1, accuracy)       # radians (~46° to ~6°)
	var distance_threshold := lerpf(0.15, 0.01, accuracy)   # meters

	var result := PackedInt32Array()
	result.append(0)  # Always keep first point

	var last_placed_idx := 0
	var cumulative_angle := 0.0
	var cumulative_dist := 0.0

	# Precompute segment directions
	var directions := PackedVector3Array()
	directions.resize(n - 1)
	for i in n - 1:
		var dir := points[i + 1] - points[i]
		var length := dir.length()
		if length > 0.00001:
			directions[i] = dir / length
		elif i > 0:
			directions[i] = directions[i - 1]
		else:
			directions[i] = Vector3.FORWARD

	for i in range(1, n - 1):
		var seg_length := points[i].distance_to(points[i - 1])
		cumulative_dist += seg_length

		# Angle between consecutive segments
		var dot := clampf(directions[i - 1].dot(directions[i]), -1.0, 1.0)
		var angle := acos(dot)
		cumulative_angle += angle

		# Place a point if either threshold is exceeded
		if cumulative_angle >= angle_threshold or cumulative_dist >= distance_threshold:
			result.append(i)
			last_placed_idx = i
			cumulative_angle = 0.0
			cumulative_dist = 0.0

	# Always keep last point
	result.append(n - 1)

	return result


# --- Smoothing ---

static func _smooth_ema(positions: PackedVector3Array, alpha: float) -> PackedVector3Array:
	var n := positions.size()
	if n < 2:
		return positions.duplicate()

	var result := PackedVector3Array()
	result.resize(n)
	result[0] = positions[0]

	for i in range(1, n):
		result[i] = result[i - 1].lerp(positions[i], alpha)

	# Reverse pass to reduce phase delay
	for i in range(n - 2, -1, -1):
		result[i] = result[i].lerp(result[i + 1], alpha * 0.5)

	return result


static func _smooth_ema_scalar(values: PackedFloat32Array, alpha: float) -> PackedFloat32Array:
	var n := values.size()
	if n < 2:
		return values.duplicate()

	var result := PackedFloat32Array()
	result.resize(n)
	result[0] = values[0]

	for i in range(1, n):
		result[i] = lerpf(result[i - 1], values[i], alpha)

	for i in range(n - 2, -1, -1):
		result[i] = lerpf(result[i], result[i + 1], alpha * 0.5)

	return result


static func _polyline_length(points: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	return length
