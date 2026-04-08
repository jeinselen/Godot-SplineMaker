class_name CurveFitting
extends RefCounted

## Converts a dense hand-drawn polyline into sparse NURBS control points.
##
## Pipeline:
## 1. Low-pass filter (exponential moving average) to remove jitter
## 2. Ramer-Douglas-Peucker simplification to reduce point count
## 3. Offset simplified points outward so the B-spline curve passes near the path


## Main entry point. Returns a SplineData from the raw drawn samples.
## accuracy: 0.0 (fewest points, smoothest) to 1.0 (most points, tightest fit)
## positions: raw controller positions in project-local space
## sizes: per-sample radius from trigger pressure
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

	# 2. Simplify with RDP
	# Epsilon inversely related to accuracy: low accuracy = large epsilon = fewer points
	var path_length := _polyline_length(smoothed)
	var epsilon := lerpf(path_length * 0.08, path_length * 0.005, accuracy)
	epsilon = maxf(epsilon, 0.001)
	var indices := _rdp_simplify(smoothed, epsilon)

	# Ensure at least 2 points
	if indices.size() < 2:
		indices = PackedInt32Array([0, positions.size() - 1])

	# 3. Extract simplified points and sizes
	var simplified_pts := PackedVector3Array()
	var simplified_sizes := PackedFloat32Array()
	for idx in indices:
		simplified_pts.append(smoothed[idx])
		simplified_sizes.append(smoothed_sizes[idx])

	# 4. Offset control points outward so the B-spline approximates the drawn path
	var offset_pts := _offset_control_points(simplified_pts, smoothed)

	# Build SplineData
	var data := SplineData.new()
	data.order_u = mini(4, offset_pts.size())
	for i in offset_pts.size():
		data.add_point(offset_pts[i], simplified_sizes[i])

	return data


## Exponential moving average filter for Vector3 positions.
## alpha: 0 = maximum smoothing, 1 = no smoothing (pass-through)
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


## Exponential moving average for scalar array.
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


## Ramer-Douglas-Peucker simplification. Returns indices of kept points.
static func _rdp_simplify(points: PackedVector3Array, epsilon: float) -> PackedInt32Array:
	var n := points.size()
	if n <= 2:
		var result := PackedInt32Array()
		for i in n:
			result.append(i)
		return result

	# Iterative RDP using a stack to avoid recursion depth issues
	var keep := PackedInt32Array()
	keep.resize(n)
	for i in n:
		keep[i] = 0
	keep[0] = 1
	keep[n - 1] = 1

	# Stack of [start, end] pairs
	var stack: Array[Vector2i] = [Vector2i(0, n - 1)]

	while not stack.is_empty():
		var range_pair: Vector2i = stack.pop_back()
		var start: int = range_pair.x
		var end: int = range_pair.y

		if end - start < 2:
			continue

		var max_dist := 0.0
		var max_idx: int = start

		var seg_start: Vector3 = points[start]
		var seg_end: Vector3 = points[end]
		var seg_dir := seg_end - seg_start
		var seg_len_sq := seg_dir.length_squared()

		for i in range(start + 1, end):
			var dist := 0.0
			if seg_len_sq < 0.00001:
				dist = points[i].distance_to(seg_start)
			else:
				var param := clampf((points[i] - seg_start).dot(seg_dir) / seg_len_sq, 0.0, 1.0)
				var proj := seg_start + seg_dir * param
				dist = points[i].distance_to(proj)

			if dist > max_dist:
				max_dist = dist
				max_idx = i

		if max_dist > epsilon:
			keep[max_idx] = 1
			stack.append(Vector2i(start, max_idx))
			stack.append(Vector2i(max_idx, end))

	var result := PackedInt32Array()
	for i in n:
		if keep[i] == 1:
			result.append(i)
	return result


## Offset simplified control points outward so the resulting B-spline
## curve passes closer to the original drawn path.
## Uses the difference between each simplified point and the local average
## of the original path to push control points away from the curve interior.
static func _offset_control_points(
	simplified: PackedVector3Array,
	original: PackedVector3Array
) -> PackedVector3Array:
	var n := simplified.size()
	if n <= 2:
		return simplified.duplicate()

	var result := PackedVector3Array()
	result.resize(n)

	# Keep first and last points as-is (they are interpolated by clamped knots)
	result[0] = simplified[0]
	result[n - 1] = simplified[n - 1]

	for i in range(1, n - 1):
		# Find the closest point on the original path
		var pt := simplified[i]
		var closest_idx := _find_closest(original, pt)

		# Compute a local average of nearby original points
		var window := maxi(3, original.size() / n)
		var avg := Vector3.ZERO
		var count := 0
		for j in range(maxi(0, closest_idx - window), mini(original.size(), closest_idx + window + 1)):
			avg += original[j]
			count += 1
		avg /= float(count)

		# The offset pushes the control point away from the local average
		# so the B-spline (which smooths toward the average) passes through the original
		var offset := pt - avg
		result[i] = pt + offset * 0.8

	return result


static func _find_closest(points: PackedVector3Array, target: Vector3) -> int:
	var best_idx := 0
	var best_dist := target.distance_squared_to(points[0])
	for i in range(1, points.size()):
		var d := target.distance_squared_to(points[i])
		if d < best_dist:
			best_dist = d
			best_idx = i
	return best_idx


static func _polyline_length(points: PackedVector3Array) -> float:
	var length := 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	return length
