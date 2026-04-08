class_name NurbsEval


## Generate a clamped (endpoint) knot vector for a non-cyclic B-spline.
## n = number of control points, k = order.
## Returns n + k knots with the first k and last k values clamped.
static func _knot_vector_clamped(n: int, k: int) -> PackedFloat32Array:
	var knot_count := n + k
	var knots := PackedFloat32Array()
	knots.resize(knot_count)
	var interior := n - k  # number of interior knots
	for i in knot_count:
		if i < k:
			knots[i] = 0.0
		elif i >= n:
			knots[i] = 1.0
		else:
			knots[i] = float(i - k + 1) / float(interior + 1)
	return knots


## Generate a uniform (periodic) knot vector for a cyclic B-spline.
## n_ext = number of extended control points (original n + k - 1), k = order.
static func _knot_vector_uniform(n_ext: int, k: int) -> PackedFloat32Array:
	var knot_count := n_ext + k
	var knots := PackedFloat32Array()
	knots.resize(knot_count)
	for i in knot_count:
		knots[i] = float(i)
	return knots


## Find the knot span index such that knots[span] <= t < knots[span+1].
## For clamped knots where t == knots[n], returns n - 1.
static func _find_span(knots: PackedFloat32Array, n: int, k: int, t: float) -> int:
	# Edge case: t at the end of the domain
	if t >= knots[n]:
		return n - 1

	# Linear search (sufficient for typical spline sizes)
	for i in range(k - 1, n):
		if t < knots[i + 1]:
			return i

	return n - 1


## Compute the k nonzero basis function values at parameter t using the
## iterative (triangular table) Cox-de Boor algorithm.
## Returns an array of k values corresponding to control points span-k+1 .. span.
static func _eval_basis(knots: PackedFloat32Array, span: int, k: int, t: float) -> PackedFloat32Array:
	var basis := PackedFloat32Array()
	basis.resize(k)
	basis[0] = 1.0

	# Left and right knot differences for the triangular table
	var left := PackedFloat32Array()
	left.resize(k)
	var right := PackedFloat32Array()
	right.resize(k)

	for j in range(1, k):
		left[j] = t - knots[span + 1 - j]
		right[j] = knots[span + j] - t
		var saved := 0.0
		for r in range(j):
			var denom := right[r + 1] + left[j - r]
			if denom == 0.0:
				# Knot multiplicity: basis value is 0 for this term
				basis[r] = saved
				saved = 0.0
			else:
				var temp := basis[r] / denom
				basis[r] = saved + right[r + 1] * temp
				saved = left[j - r] * temp
		basis[j] = saved

	return basis


## Evaluate a single point on a NURBS curve at parameter t.
## points/weights are the (possibly extended) control point arrays.
## knots is the full knot vector. k is the order.
static func _eval_rational_point(
	points: PackedVector3Array,
	weights: PackedFloat32Array,
	knots: PackedFloat32Array,
	k: int,
	n: int,
	t: float
) -> Vector3:
	var span := _find_span(knots, n, k, t)
	var basis := _eval_basis(knots, span, k, t)

	var numerator := Vector3.ZERO
	var denominator := 0.0
	for i in k:
		var idx := span - k + 1 + i
		var bw := basis[i] * weights[idx]
		numerator += points[idx] * bw
		denominator += bw

	if denominator == 0.0:
		return Vector3.ZERO
	return numerator / denominator


## Evaluate a single scalar value (e.g., radius) on a NURBS curve at parameter t.
static func _eval_rational_scalar(
	values: PackedFloat32Array,
	weights: PackedFloat32Array,
	knots: PackedFloat32Array,
	k: int,
	n: int,
	t: float
) -> float:
	var span := _find_span(knots, n, k, t)
	var basis := _eval_basis(knots, span, k, t)

	var numerator := 0.0
	var denominator := 0.0
	for i in k:
		var idx := span - k + 1 + i
		var bw := basis[i] * weights[idx]
		numerator += values[idx] * bw
		denominator += bw

	if denominator == 0.0:
		return 0.0
	return numerator / denominator


## Evaluate the full NURBS curve, returning an array of 3D points.
static func eval_curve(data: SplineData) -> PackedVector3Array:
	var n := data.point_count()
	if n < 2:
		return data.points.duplicate()

	var k := data.effective_order()
	var result := PackedVector3Array()

	if data.cyclic:
		result = _eval_curve_cyclic(data.points, data.weights, n, k, data.resolution_u)
	else:
		result = _eval_curve_clamped(data.points, data.weights, n, k, data.resolution_u)

	return result


## Evaluate per-point radii along the curve (same parameterization as eval_curve).
static func eval_curve_sizes(data: SplineData) -> PackedFloat32Array:
	var n := data.point_count()
	if n < 2:
		return data.sizes.duplicate()

	var k := data.effective_order()

	if data.cyclic:
		return _eval_sizes_cyclic(data.sizes, data.weights, n, k, data.resolution_u)
	else:
		return _eval_sizes_clamped(data.sizes, data.weights, n, k, data.resolution_u)


# --- Non-cyclic evaluation ---

static func _eval_curve_clamped(
	points: PackedVector3Array,
	weights: PackedFloat32Array,
	n: int,
	k: int,
	resolution: int
) -> PackedVector3Array:
	var knots := _knot_vector_clamped(n, k)
	var segments := maxi(1, (n - 1) * resolution)
	var result := PackedVector3Array()
	result.resize(segments + 1)

	for i in segments + 1:
		var t := float(i) / float(segments)
		# Clamp to valid domain to avoid floating point edge issues
		t = clampf(t, 0.0, 1.0)
		result[i] = _eval_rational_point(points, weights, knots, k, n, t)

	return result


static func _eval_sizes_clamped(
	sizes: PackedFloat32Array,
	weights: PackedFloat32Array,
	n: int,
	k: int,
	resolution: int
) -> PackedFloat32Array:
	var knots := _knot_vector_clamped(n, k)
	var segments := maxi(1, (n - 1) * resolution)
	var result := PackedFloat32Array()
	result.resize(segments + 1)

	for i in segments + 1:
		var t := clampf(float(i) / float(segments), 0.0, 1.0)
		result[i] = _eval_rational_scalar(sizes, weights, knots, k, n, t)

	return result


# --- Cyclic evaluation ---

static func _eval_curve_cyclic(
	points: PackedVector3Array,
	weights: PackedFloat32Array,
	n: int,
	k: int,
	resolution: int
) -> PackedVector3Array:
	# Extend control points by wrapping k-1 points from the beginning
	var ext_points := PackedVector3Array()
	var ext_weights := PackedFloat32Array()
	var n_ext := n + k - 1
	ext_points.resize(n_ext)
	ext_weights.resize(n_ext)
	for i in n_ext:
		ext_points[i] = points[i % n]
		ext_weights[i] = weights[i % n]

	var knots := _knot_vector_uniform(n_ext, k)

	# Valid parameter domain for the cyclic curve
	var t_start := float(k - 1)
	var t_end := float(n)
	var segments := maxi(1, n * resolution)

	var result := PackedVector3Array()
	result.resize(segments + 1)
	for i in segments + 1:
		var frac := float(i) / float(segments)
		var t := t_start + frac * (t_end - t_start)
		# Clamp to just inside the domain to avoid edge issues
		t = clampf(t, t_start, t_end - 0.0001)
		result[i] = _eval_rational_point(ext_points, ext_weights, knots, k, n_ext, t)

	return result


static func _eval_sizes_cyclic(
	sizes: PackedFloat32Array,
	weights: PackedFloat32Array,
	n: int,
	k: int,
	resolution: int
) -> PackedFloat32Array:
	var ext_sizes := PackedFloat32Array()
	var ext_weights := PackedFloat32Array()
	var n_ext := n + k - 1
	ext_sizes.resize(n_ext)
	ext_weights.resize(n_ext)
	for i in n_ext:
		ext_sizes[i] = sizes[i % n]
		ext_weights[i] = weights[i % n]

	var knots := _knot_vector_uniform(n_ext, k)

	var t_start := float(k - 1)
	var t_end := float(n)
	var segments := maxi(1, n * resolution)

	var result := PackedFloat32Array()
	result.resize(segments + 1)
	for i in segments + 1:
		var frac := float(i) / float(segments)
		var t := t_start + frac * (t_end - t_start)
		t = clampf(t, t_start, t_end - 0.0001)
		result[i] = _eval_rational_scalar(ext_sizes, ext_weights, knots, k, n_ext, t)

	return result
