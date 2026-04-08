extends Node3D


func _ready() -> void:
	_create_axis_display()


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
