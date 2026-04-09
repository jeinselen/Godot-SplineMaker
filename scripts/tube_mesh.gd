class_name TubeMesh

## Number of latitude rings for hemisphere end caps (half the mesh resolution).
static func _cap_rings(edge_count: int) -> int:
	return maxi(edge_count / 2, 1)


## Generate a tube mesh from a polyline with per-point radii.
## edge_count = number of vertices around each cross-section ring.
## cyclic = true omits end caps and connects the last ring to the first.
static func generate(
	polyline: PackedVector3Array,
	radii: PackedFloat32Array,
	edge_count: int,
	cyclic: bool
) -> ArrayMesh:
	var point_count := polyline.size()
	if point_count < 2:
		return ArrayMesh.new()

	edge_count = maxi(edge_count, 3)

	# Build parallel transport frames
	var tangents := _compute_tangents(polyline, cyclic)
	var normals: Array[Vector3] = []
	var binormals: Array[Vector3] = []
	_compute_frames(tangents, cyclic, normals, binormals)

	# Build mesh using SurfaceTool
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Generate tube body rings
	for i in point_count:
		var center := polyline[i]
		var n_vec := normals[i]
		var b_vec := binormals[i]
		var radius: float = radii[i] if i < radii.size() else 0.1
		for j in edge_count:
			var angle := TAU * float(j) / float(edge_count)
			var offset := n_vec * (cos(angle) * radius) + b_vec * (sin(angle) * radius)
			var vert := center + offset
			var normal := offset.normalized()
			st.set_normal(normal)
			st.add_vertex(vert)

	# Connect rings with triangles
	var ring_count := point_count
	var loop_end := ring_count - 1 if not cyclic else ring_count
	for i in loop_end:
		var i_next := (i + 1) % ring_count
		for j in edge_count:
			var j_next := (j + 1) % edge_count
			var a := i * edge_count + j
			var b := i_next * edge_count + j
			var c := i_next * edge_count + j_next
			var d := i * edge_count + j_next
			# Two triangles per quad
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(a)
			st.add_index(c)
			st.add_index(d)

	# End caps for non-cyclic splines
	if not cyclic:
		var body_vert_count := point_count * edge_count
		_add_hemisphere_cap(st, polyline[0], tangents[0], normals[0], binormals[0],
			radii[0], edge_count, true, body_vert_count)
		var last := point_count - 1
		var cap2_offset := body_vert_count + _cap_vertex_count(edge_count)
		_add_hemisphere_cap(st, polyline[last], tangents[last], normals[last], binormals[last],
			radii[last], edge_count, false, cap2_offset)

	var mesh := st.commit()
	return mesh


## Compute tangent vectors along the polyline.
static func _compute_tangents(polyline: PackedVector3Array, cyclic: bool) -> Array[Vector3]:
	var n := polyline.size()
	var tangents: Array[Vector3] = []
	tangents.resize(n)

	for i in n:
		var t: Vector3
		if cyclic:
			var prev := (i - 1 + n) % n
			var next := (i + 1) % n
			t = (polyline[next] - polyline[prev]).normalized()
		else:
			if i == 0:
				t = (polyline[1] - polyline[0]).normalized()
			elif i == n - 1:
				t = (polyline[n - 1] - polyline[n - 2]).normalized()
			else:
				t = (polyline[i + 1] - polyline[i - 1]).normalized()
		# Handle degenerate (zero-length) segments
		if t.length_squared() < 0.0001:
			t = Vector3.FORWARD if i == 0 else tangents[i - 1]
		tangents[i] = t

	return tangents


## Build parallel transport frames (normals and binormals) from tangents.
static func _compute_frames(
	tangents: Array[Vector3],
	cyclic: bool,
	out_normals: Array[Vector3],
	out_binormals: Array[Vector3]
) -> void:
	var n := tangents.size()
	out_normals.resize(n)
	out_binormals.resize(n)

	# Initial normal: perpendicular to first tangent
	var t0 := tangents[0]
	var ref := Vector3.UP
	if absf(t0.dot(ref)) > 0.99:
		ref = Vector3.RIGHT
	out_normals[0] = t0.cross(ref).normalized()
	out_binormals[0] = t0.cross(out_normals[0]).normalized()

	# Propagate frames using parallel transport
	for i in range(1, n):
		var axis := tangents[i - 1].cross(tangents[i])
		if axis.length_squared() < 0.00001:
			# Tangents are nearly parallel, carry frame forward
			out_normals[i] = out_normals[i - 1]
		else:
			axis = axis.normalized()
			var cos_angle := clampf(tangents[i - 1].dot(tangents[i]), -1.0, 1.0)
			var angle := acos(cos_angle)
			out_normals[i] = out_normals[i - 1].rotated(axis, angle)
		out_binormals[i] = tangents[i].cross(out_normals[i]).normalized()

	# For cyclic curves, correct the accumulated twist
	if cyclic and n > 2:
		_correct_cyclic_twist(tangents, out_normals, out_binormals)


## Distribute accumulated twist correction evenly for cyclic curves.
static func _correct_cyclic_twist(
	tangents: Array[Vector3],
	normals: Array[Vector3],
	binormals: Array[Vector3]
) -> void:
	var n := normals.size()

	# Measure twist between the transported frame at the end and the frame at the start
	# Project the final normal onto the plane perpendicular to tangent[0]
	var n_final := normals[n - 1]
	var n_start := normals[0]
	var t := tangents[0]

	# Angle between the two normals projected onto the tangent plane
	var cos_twist := clampf(n_final.dot(n_start), -1.0, 1.0)
	var sin_twist := n_final.cross(n_start).dot(t)
	var twist_angle := atan2(sin_twist, cos_twist)

	# Distribute correction
	for i in range(1, n):
		var correction := twist_angle * float(i) / float(n)
		normals[i] = normals[i].rotated(tangents[i], correction)
		binormals[i] = tangents[i].cross(normals[i]).normalized()


## Returns the number of vertices added by one hemisphere cap.
static func _cap_vertex_count(edge_count: int) -> int:
	return _cap_rings(edge_count) * edge_count + 1


## Add a hemisphere end cap. is_start=true faces backward along -tangent (start cap).
static func _add_hemisphere_cap(
	st: SurfaceTool,
	center: Vector3,
	tangent: Vector3,
	normal: Vector3,
	binormal: Vector3,
	radius: float,
	edge_count: int,
	is_start: bool,
	vert_offset: int
) -> void:
	var cap_dir := -tangent if is_start else tangent

	# Generate latitude rings from equator toward pole
	var cap_rings := _cap_rings(edge_count)
	for lat in range(1, cap_rings + 1):
		var phi := (PI / 2.0) * float(lat) / float(cap_rings)
		var ring_radius := radius * cos(phi)
		var ring_offset := radius * sin(phi)
		var ring_center := center + cap_dir * ring_offset
		for j in edge_count:
			var angle := TAU * float(j) / float(edge_count)
			var offset := normal * (cos(angle) * ring_radius) + binormal * (sin(angle) * ring_radius)
			var vert := ring_center + offset
			var vert_normal := (vert - center).normalized()
			st.set_normal(vert_normal)
			st.add_vertex(vert)

	# Pole vertex
	var pole := center + cap_dir * radius
	st.set_normal(cap_dir)
	st.add_vertex(pole)

	# Connect the equator ring (tube body boundary) to the first cap ring
	# The equator ring is the first or last ring of the tube body
	var equator_base: int
	if is_start:
		equator_base = 0  # first ring of tube body
	else:
		# last ring of tube body is at (point_count - 1) * edge_count
		# but we receive vert_offset which accounts for body + previous cap
		# The last body ring starts at vert_offset - edge_count...
		# Actually, the caller must handle this. Let's use the ring indices directly.
		# For the end cap, the equator is the last tube ring.
		# We know the body has N rings, the last starts at (N-1)*edge_count.
		# But we don't have N here. Instead, let's compute it from vert_offset.
		# For start cap: vert_offset = body_vert_count, equator = ring 0 = index 0
		# For end cap: vert_offset = body_vert_count + start_cap_verts
		# equator = last ring = body_vert_count - edge_count
		pass

	# Determine equator ring vertex indices
	if is_start:
		equator_base = 0
	else:
		# The end cap equator is the last ring of the tube body.
		# body_vert_count = vert_offset - _cap_vertex_count(edge_count) for end cap
		var body_vert_count := vert_offset - _cap_vertex_count(edge_count)
		equator_base = body_vert_count - edge_count

	var first_cap_ring := vert_offset  # first latitude ring of the cap

	# Winding order depends on cap direction
	for j in edge_count:
		var j_next := (j + 1) % edge_count
		var eq_a := equator_base + j
		var eq_b := equator_base + j_next
		var cap_a := first_cap_ring + j
		var cap_b := first_cap_ring + j_next
		if is_start:
			st.add_index(eq_a)
			st.add_index(cap_b)
			st.add_index(cap_a)
			st.add_index(eq_a)
			st.add_index(eq_b)
			st.add_index(cap_b)
		else:
			st.add_index(eq_a)
			st.add_index(cap_a)
			st.add_index(cap_b)
			st.add_index(eq_a)
			st.add_index(cap_b)
			st.add_index(eq_b)

	# Connect successive latitude rings
	for lat in range(cap_rings - 1):
		var ring_a := vert_offset + lat * edge_count
		var ring_b := vert_offset + (lat + 1) * edge_count
		for j in edge_count:
			var j_next := (j + 1) % edge_count
			var a := ring_a + j
			var b := ring_b + j
			var c := ring_b + j_next
			var d := ring_a + j_next
			if is_start:
				st.add_index(a)
				st.add_index(c)
				st.add_index(b)
				st.add_index(a)
				st.add_index(d)
				st.add_index(c)
			else:
				st.add_index(a)
				st.add_index(b)
				st.add_index(c)
				st.add_index(a)
				st.add_index(c)
				st.add_index(d)

	# Connect last latitude ring to pole
	var last_ring := vert_offset + (cap_rings - 1) * edge_count
	var pole_idx := vert_offset + cap_rings * edge_count
	for j in edge_count:
		var j_next := (j + 1) % edge_count
		if is_start:
			st.add_index(last_ring + j)
			st.add_index(last_ring + j_next)
			st.add_index(pole_idx)
		else:
			st.add_index(last_ring + j)
			st.add_index(pole_idx)
			st.add_index(last_ring + j_next)
