extends Node3D


func _ready() -> void:
	_create_axis_display()
	_create_test_splines()


func _create_test_splines() -> void:
	# Test 1: Straight line along X (order 4, uniform size)
	var straight := SplineData.new()
	straight.order_u = 4
	for i in 5:
		straight.add_point(Vector3(float(i) * 0.25, 0.0, 0.0), 0.02)
	_add_spline(straight)

	# Test 2: S-curve in XZ plane with varying radius
	var s_curve := SplineData.new()
	s_curve.order_u = 4
	s_curve.add_point(Vector3(0.0, 0.5, 0.0), 0.01)
	s_curve.add_point(Vector3(0.25, 0.5, 0.0), 0.02)
	s_curve.add_point(Vector3(0.5, 0.5, 0.25), 0.03)
	s_curve.add_point(Vector3(0.75, 0.5, 0.25), 0.02)
	s_curve.add_point(Vector3(1.0, 0.5, 0.0), 0.01)
	_add_spline(s_curve, true)

	# Test 3: Cyclic loop (square-ish shape, order 3)
	var loop := SplineData.new()
	loop.order_u = 3
	loop.cyclic = true
	loop.add_point(Vector3(0.0, 1.0, 0.25), 0.015)
	loop.add_point(Vector3(0.25, 1.0, 0.0), 0.015)
	loop.add_point(Vector3(0.5, 1.0, 0.25), 0.015)
	loop.add_point(Vector3(0.25, 1.0, 0.5), 0.015)
	_add_spline(loop)

	# Test 4: Minimal 2-point spline (tests order soft-clamping)
	var minimal := SplineData.new()
	minimal.order_u = 4
	minimal.add_point(Vector3(0.0, -0.5, 0.0), 0.02)
	minimal.add_point(Vector3(0.5, -0.5, 0.0), 0.02)
	_add_spline(minimal)


func _add_spline(data: SplineData, active: bool = false) -> void:
	var node := SplineNode.new()
	add_child(node)
	node.set_data(data)
	if active:
		node.set_active(true)


func _create_axis_display() -> void:
	var mesh := ImmediateMesh.new()
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = mesh
	mesh_instance.name = "AxisDisplay"
	add_child(mesh_instance)

	# X axis (red)
	var mat_x := StandardMaterial3D.new()
	mat_x.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_x.albedo_color = Color(1.0, 0.2, 0.2, 0.8)
	mat_x.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat_x)
	mesh.surface_add_vertex(Vector3(-1.0, 0.0, 0.0))
	mesh.surface_add_vertex(Vector3(1.0, 0.0, 0.0))
	mesh.surface_end()

	# Y axis (green)
	var mat_y := StandardMaterial3D.new()
	mat_y.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_y.albedo_color = Color(0.2, 1.0, 0.2, 0.8)
	mat_y.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat_y)
	mesh.surface_add_vertex(Vector3(0.0, -1.0, 0.0))
	mesh.surface_add_vertex(Vector3(0.0, 1.0, 0.0))
	mesh.surface_end()

	# Z axis (blue)
	var mat_z := StandardMaterial3D.new()
	mat_z.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_z.albedo_color = Color(0.2, 0.4, 1.0, 0.8)
	mat_z.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, mat_z)
	mesh.surface_add_vertex(Vector3(0.0, 0.0, -1.0))
	mesh.surface_add_vertex(Vector3(0.0, 0.0, 1.0))
	mesh.surface_end()
