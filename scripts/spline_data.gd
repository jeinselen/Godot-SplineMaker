class_name SplineData
extends Resource

var order_u: int = 4
var cyclic: bool = false
var points: PackedVector3Array = PackedVector3Array()
var sizes: PackedFloat32Array = PackedFloat32Array()
var weights: PackedFloat32Array = PackedFloat32Array()


func add_point(position: Vector3, size: float = 0.1, weight: float = 1.0) -> void:
	points.append(position)
	sizes.append(size)
	weights.append(weight)


func insert_point(index: int, position: Vector3, size: float = 0.1, weight: float = 1.0) -> void:
	points = _insert_vec3(points, index, position)
	sizes = _insert_float(sizes, index, size)
	weights = _insert_float(weights, index, weight)


func remove_point(index: int) -> void:
	points = _remove_vec3(points, index)
	sizes = _remove_float(sizes, index)
	weights = _remove_float(weights, index)


func point_count() -> int:
	return points.size()


func is_endpoint(index: int) -> bool:
	if point_count() == 0:
		return false
	return index == 0 or index == point_count() - 1


## Returns the effective order, soft-clamped to the number of control points.
func effective_order() -> int:
	return mini(order_u, points.size())


## Merges adjacent points whose positions match within epsilon. The surviving
## point's size and weight are the averages of the two merged points. For
## cyclic splines, also merges across the seam (last -> first). Refuses any
## individual merge that would leave fewer than 2 points. Returns true if at
## least one merge occurred.
func merge_adjacent_duplicates(epsilon: float = 1e-5) -> bool:
	if point_count() < 3:
		# A 2-point spline can't be merged (would leave 1 point), and 0/1
		# point splines have nothing to merge.
		return false

	var merged_any := false
	var i := 0
	while i < point_count() - 1 and point_count() > 2:
		if points[i].distance_to(points[i + 1]) <= epsilon:
			sizes[i] = (sizes[i] + sizes[i + 1]) * 0.5
			weights[i] = (weights[i] + weights[i + 1]) * 0.5
			remove_point(i + 1)
			merged_any = true
			# Don't increment i — re-check the same index against the new neighbor.
		else:
			i += 1

	# Cyclic seam: last point against first.
	if cyclic and point_count() > 2:
		var last := point_count() - 1
		if points[0].distance_to(points[last]) <= epsilon:
			sizes[0] = (sizes[0] + sizes[last]) * 0.5
			weights[0] = (weights[0] + weights[last]) * 0.5
			remove_point(last)
			merged_any = true

	return merged_any


# --- PackedArray helpers (no built-in insert/remove) ---

static func _insert_vec3(arr: PackedVector3Array, index: int, value: Vector3) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(arr.size() + 1)
	for i in index:
		result[i] = arr[i]
	result[index] = value
	for i in range(index, arr.size()):
		result[i + 1] = arr[i]
	return result


static func _remove_vec3(arr: PackedVector3Array, index: int) -> PackedVector3Array:
	var result := PackedVector3Array()
	result.resize(arr.size() - 1)
	for i in index:
		result[i] = arr[i]
	for i in range(index + 1, arr.size()):
		result[i - 1] = arr[i]
	return result


static func _insert_float(arr: PackedFloat32Array, index: int, value: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(arr.size() + 1)
	for i in index:
		result[i] = arr[i]
	result[index] = value
	for i in range(index, arr.size()):
		result[i + 1] = arr[i]
	return result


static func _remove_float(arr: PackedFloat32Array, index: int) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	result.resize(arr.size() - 1)
	for i in index:
		result[i] = arr[i]
	for i in range(index + 1, arr.size()):
		result[i - 1] = arr[i]
	return result
