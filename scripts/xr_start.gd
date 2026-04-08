extends Node3D

## Maximum refresh rate to request from the XR runtime.
@export var maximum_refresh_rate: int = 90

var xr_interface: OpenXRInterface
var xr_is_focused: bool = false

@onready var world_environment: WorldEnvironment = $WorldEnvironment


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		print("OpenXR initialized successfully.")

		var vp: Viewport = get_viewport()
		vp.use_xr = true

		# VSync is handled by OpenXR compositor
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

		# Enable variable rate shading if supported
		if RenderingServer.get_rendering_device():
			vp.vrs_mode = Viewport.VRS_XR
		elif int(ProjectSettings.get_setting("xr/openxr/foveation_level")) == 0:
			push_warning("OpenXR: Recommend setting foveation level to High.")

		# Connect session lifecycle signals (passthrough enabled after session begins)
		xr_interface.session_begun.connect(_on_openxr_session_begun)
		xr_interface.session_visible.connect(_on_openxr_visible_state)
		xr_interface.session_focussed.connect(_on_openxr_focused_state)
		xr_interface.session_stopping.connect(_on_openxr_stopping)
		xr_interface.pose_recentered.connect(_on_openxr_pose_recentered)
	else:
		push_error("OpenXR not initialized. Check headset connection.")
		# Don't quit in editor, only on device
		if not Engine.is_editor_hint():
			get_tree().quit()

	# Connect controller input signals for logging
	_setup_controller_signals($XROrigin3D/LeftController, "Left")
	_setup_controller_signals($XROrigin3D/RightController, "Right")


func _enable_passthrough() -> void:
	# Create a minimal environment if none exists on the WorldEnvironment node
	if not world_environment.environment:
		world_environment.environment = Environment.new()

	var supported_modes: Array = xr_interface.get_supported_environment_blend_modes()
	print("Passthrough: Supported blend modes = ", supported_modes)
	if XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND in supported_modes:
		xr_interface.environment_blend_mode = XRInterface.XR_ENV_BLEND_MODE_ALPHA_BLEND
		get_viewport().transparent_bg = true
		world_environment.environment.background_mode = Environment.BG_COLOR
		world_environment.environment.background_color = Color(0.0, 0.0, 0.0, 0.0)
		world_environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		world_environment.environment.ambient_light_color = Color(1.0, 1.0, 1.0)
		world_environment.environment.ambient_light_energy = 0.5
		print("Passthrough: alpha blend enabled.")
	else:
		push_warning("Passthrough: XR_ENV_BLEND_MODE_ALPHA_BLEND not supported on this device.")
		# Fallback: set a dark background so the app is still usable
		world_environment.environment.background_mode = Environment.BG_COLOR
		world_environment.environment.background_color = Color(0.1, 0.1, 0.1, 1.0)


func _setup_controller_signals(controller: XRController3D, label: String) -> void:
	controller.button_pressed.connect(
		func(action: String) -> void: print(label, " button pressed: ", action))
	controller.button_released.connect(
		func(action: String) -> void: print(label, " button released: ", action))
	controller.input_float_changed.connect(
		func(action: String, value: float) -> void: print(label, " float: ", action, " = ", value))
	controller.input_vector2_changed.connect(
		func(action: String, value: Vector2) -> void: print(label, " vec2: ", action, " = ", value))


func _on_openxr_session_begun() -> void:
	print("OpenXR: Session begun.")

	# Configure passthrough now that the session is active
	_enable_passthrough()

	# Request the highest available refresh rate up to maximum_refresh_rate
	var current_rate: float = xr_interface.get_display_refresh_rate()
	if current_rate > 0:
		print("OpenXR: Current refresh rate = ", current_rate)

	var new_rate: float = current_rate
	var available_rates: Array = xr_interface.get_available_display_refresh_rates()
	if available_rates.is_empty():
		print("OpenXR: Refresh rate extension not available.")
	else:
		for rate in available_rates:
			if rate > new_rate and rate <= maximum_refresh_rate:
				new_rate = rate

	if current_rate != new_rate:
		print("OpenXR: Setting refresh rate to ", new_rate)
		xr_interface.set_display_refresh_rate(new_rate)

	# Sync physics tick rate with display refresh rate
	var final_rate: float = xr_interface.get_display_refresh_rate()
	if final_rate > 0:
		Engine.physics_ticks_per_second = roundi(final_rate)
		print("OpenXR: Physics ticks set to ", Engine.physics_ticks_per_second)


func _on_openxr_visible_state() -> void:
	# Session is visible but not focused (e.g. headset removed, system overlay)
	if xr_is_focused:
		print("OpenXR: Lost focus, pausing.")
		xr_is_focused = false
		get_tree().paused = true


func _on_openxr_focused_state() -> void:
	print("OpenXR: Gained focus, resuming.")
	xr_is_focused = true
	get_tree().paused = false


func _on_openxr_stopping() -> void:
	print("OpenXR: Session stopping.")
	# Export project JSON on app close
	var pm = get_node_or_null("%ProjectManager")
	if pm and pm.has_method("close_project"):
		pm.close_project()


func _on_openxr_pose_recentered() -> void:
	print("OpenXR: Pose recentered.")


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Ensure project export on window close (desktop testing fallback)
		var pm = get_node_or_null("%ProjectManager")
		if pm and pm.has_method("close_project"):
			pm.close_project()
