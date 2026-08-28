extends Node

## Top-level app state machine. Manages transitions between main menu and
## in-project states, holds settings, and owns the active UI panel.

@onready var project_manager: Node = %ProjectManager
@onready var project_space: Node3D = %ProjectSpace
@onready var interaction: Node = %Interaction
@onready var left_controller: XRController3D = %LeftController
@onready var right_controller: XRController3D = %RightController
@onready var xr_camera: XRCamera3D = %XRCamera3D

enum AppState { MAIN_MENU, IN_PROJECT }
var state: AppState = AppState.MAIN_MENU

var settings := SettingsData.new()
var active_panel: XRPanel = null
var _active_keyboard: XRKeyboard = null

# --- Content placement ---

## Where the project space lands, relative to the camera, when (re)placed:
## a fixed distance ahead and slightly below eye level.
const PROJECT_DISTANCE := 0.75
const PROJECT_HEIGHT_OFFSET := -0.1

## True once content has been placed against a live (tracked) camera pose. The
## first placement is deferred out of _ready(): at that point the headset pose
## is not yet valid, which is what made content spawn meters from the user.
var _experience_placed := false
## Set by request_recenter(); consumed on the next _process frame so the camera
## pose is guaranteed applied before we place content against it.
var _recenter_pending := false


func _ready() -> void:
	settings.load_from_file()
	# Apply settings to project manager
	project_manager.max_undo_steps = settings.max_undo_steps
	project_manager.autosave_delay = settings.autosave_delay
	project_manager.export_directory = settings.export_directory
	project_manager.preview_mesh_resolution = settings.preview_mesh_resolution
	project_manager.preview_spline_resolution = settings.preview_spline_resolution

	# Request storage permissions on Android (needed for importing external files)
	if OS.get_name() == "Android":
		OS.request_permissions()

	# Hide project space and action areas until a project is opened
	project_space.visible = false
	interaction.set_action_areas_visible(false)

	# Start at main menu. The panel is created now but its final placement waits
	# for a live camera pose (see _process / request_recenter).
	_enter_main_menu()


func _process(_delta: float) -> void:
	# Perform a requested recenter here rather than inline, so the XR camera pose
	# has been applied for this frame before we read it. This is what ties the
	# app to the user's actual location instead of the scene origin.
	if _recenter_pending:
		_recenter_pending = false
		_experience_placed = true
		recenter_experience()


## Called by xr_start when tracking first becomes live (initial open) and again
## whenever the OS recenters the pose — the base location set by press-and-hold
## on the Meta button, which the Meta OS also uses to place windowed apps.
## `force` recenters even if content was already placed; without it, only the
## first (initial-open) call takes effect, so re-donning the headset does not
## teleport everything.
func request_recenter(force: bool) -> void:
	if force or not _experience_placed:
		_recenter_pending = true


## Re-present all active content directly in front of the user, using the live
## camera pose. Single source of truth for "put things where I am": app open,
## OS pose-recenter, and the manual view reset all funnel here.
func recenter_experience() -> void:
	if state == AppState.IN_PROJECT:
		project_space.global_transform = _front_of_camera(PROJECT_DISTANCE, PROJECT_HEIGHT_OFFSET)
	reset_panel_position()


## A yaw-aligned transform placed in front of the camera on the horizontal plane
## (upright, facing the user). Used to drop the project space ahead of the user.
func _front_of_camera(distance: float, height: float) -> Transform3D:
	var cam_t := xr_camera.global_transform
	var cam_forward := -cam_t.basis.z
	var horizontal_forward := Vector3(cam_forward.x, 0.0, cam_forward.z)
	if horizontal_forward.length() < 0.0001:
		horizontal_forward = Vector3(0.0, 0.0, -1.0)
	horizontal_forward = horizontal_forward.normalized()
	var origin := cam_t.origin + horizontal_forward * distance + Vector3.UP * height
	var basis := Basis.looking_at(horizontal_forward, Vector3.UP)
	return Transform3D(basis, origin)


# --- State transitions ---

func open_project(dir_name: String) -> void:
	_destroy_active_panel()
	project_manager.open_project(dir_name)
	_apply_preview_settings()
	interaction.warm_up_drawing_pipeline(settings.preview_mesh_resolution, settings.preview_spline_resolution)
	project_space.visible = true
	project_space.global_transform = _front_of_camera(PROJECT_DISTANCE, PROJECT_HEIGHT_OFFSET)
	state = AppState.IN_PROJECT

	interaction.set_action_areas_visible(true)
	interaction.set_mode(interaction.Mode.SIZE)

	_create_in_project_panel()


func create_and_open_project() -> void:
	_destroy_active_panel()
	project_manager.create_new_project()
	interaction.warm_up_drawing_pipeline(settings.preview_mesh_resolution, settings.preview_spline_resolution)
	project_space.visible = true
	project_space.global_transform = _front_of_camera(PROJECT_DISTANCE, PROJECT_HEIGHT_OFFSET)
	state = AppState.IN_PROJECT
	interaction.set_action_areas_visible(true)
	interaction.set_mode(interaction.Mode.SIZE)
	_create_in_project_panel()


## Imports a JSON file from the export directory as a new project and opens it.
func import_and_open_project(json_path: String) -> void:
	var dir_name: String = project_manager.import_project_from_json(json_path)
	if dir_name.is_empty():
		show_popup("Import failed:\n" + json_path.get_file(), Color(1.0, 0.3, 0.3))
		return
	open_project(dir_name)


func close_project() -> void:
	_destroy_active_panel()
	# Clear selection and hover state before freeing SplineNodes
	interaction.select_spline(null)
	interaction.clear_hover_sets()
	project_manager.close_project()
	project_space.visible = false
	interaction.set_action_areas_visible(false)
	state = AppState.MAIN_MENU
	_enter_main_menu()


func _enter_main_menu() -> void:
	state = AppState.MAIN_MENU
	_create_main_menu_panel()


# --- Panel management ---

func _create_main_menu_panel() -> void:
	var panel := MainMenuPanel.create_panel(self)
	add_child(panel)
	panel.setup(left_controller, right_controller)
	panel.reset_position(xr_camera)
	active_panel = panel


func _create_in_project_panel() -> void:
	var panel := InProjectPanel.create_panel(self)
	add_child(panel)
	panel.setup(left_controller, right_controller)
	panel.reset_position(xr_camera)
	active_panel = panel


func _destroy_active_panel() -> void:
	dismiss_keyboard()
	if active_panel and is_instance_valid(active_panel):
		active_panel.queue_free()
		active_panel = null


## Spawn a virtual keyboard variant for the given input control, positioned
## just below the panel that owns it. Returns the spawned keyboard so callers
## can hook its cancelled/dismissed signals.
func request_keyboard(target: Control, kind: String, anchor_panel: XRPanel) -> XRKeyboard:
	# Idempotent: if a keyboard is already open for this same target, return it.
	if _active_keyboard and is_instance_valid(_active_keyboard) and _active_keyboard.target_control == target:
		return _active_keyboard
	dismiss_keyboard()

	var kb: XRKeyboard
	if kind == "numpad":
		kb = XRKeyboardNumpad.create_panel(target)
	else:
		kb = XRKeyboardQWERTY.create_panel(target)

	add_child(kb)
	kb.setup(left_controller, right_controller)
	kb.dismissed.connect(dismiss_keyboard)

	# Position below the anchor panel in its local frame so it stays aligned.
	var anchor_t := anchor_panel.global_transform
	var anchor_h := anchor_panel.panel_size.y * anchor_panel.pixel_size
	var kb_h := kb.panel_size.y * kb.pixel_size
	var down_offset := -(anchor_h * 0.5 + kb_h * 0.5 + 0.02)
	var local_offset := Vector3(0.0, down_offset, 0.0)
	kb.global_transform = Transform3D(anchor_t.basis, anchor_t.origin + anchor_t.basis * local_offset)

	_active_keyboard = kb
	return kb


func dismiss_keyboard() -> void:
	if _active_keyboard and is_instance_valid(_active_keyboard):
		_active_keyboard.queue_free()
	_active_keyboard = null


## True when a virtual keyboard is currently open. Used by interaction.gd to
## suppress drawing/extrude/grip/joystick actions so trigger taps go to the
## keyboard only.
func is_keyboard_active() -> bool:
	return _active_keyboard != null and is_instance_valid(_active_keyboard)


## Reposition the active panel directly in front of the camera.
func reset_panel_position() -> void:
	if active_panel and is_instance_valid(active_panel):
		active_panel.reset_position(xr_camera)


## Show a popup in front of the camera.
func show_popup(text: String, color: Color = Color.WHITE, dismiss_time: float = 30.0) -> XRPopup:
	var popup := XRPopup.create(text, color, dismiss_time)
	get_tree().root.add_child(popup)
	popup.setup(left_controller, right_controller)
	popup.reset_position(xr_camera)
	return popup


# --- Queries for other scripts ---

## Returns true if the given controller is pointing at the active panel.
func is_pointing_at_panel(controller_id: int) -> bool:
	if active_panel and is_instance_valid(active_panel):
		return active_panel.is_controller_pointing(controller_id)
	return false


## Returns true if the given controller is grabbing the active panel.
func is_panel_grabbed(controller_id: int) -> bool:
	if active_panel and is_instance_valid(active_panel):
		return active_panel.is_grabbed_by(controller_id)
	return false


## Returns true if any panel is currently grabbed.
func is_any_panel_grabbed() -> bool:
	if active_panel and is_instance_valid(active_panel):
		return active_panel.is_grabbed()
	return false


## Apply updated settings. Called by settings panel.
func apply_settings() -> void:
	settings.save_to_file()
	project_manager.max_undo_steps = settings.max_undo_steps
	project_manager.autosave_delay = settings.autosave_delay
	project_manager.export_directory = settings.export_directory
	project_manager.preview_mesh_resolution = settings.preview_mesh_resolution
	project_manager.preview_spline_resolution = settings.preview_spline_resolution
	interaction.warm_up_drawing_pipeline(settings.preview_mesh_resolution, settings.preview_spline_resolution)
	_apply_preview_settings()


## Update mesh and spline resolution on all spline nodes in the project.
func _apply_preview_settings() -> void:
	var mesh_res := settings.preview_mesh_resolution
	var spline_res := settings.preview_spline_resolution
	for child in project_space.get_children():
		if child is SplineNode:
			child.mesh_edge_count = mesh_res
			child.spline_resolution = spline_res
			child.mark_dirty()
