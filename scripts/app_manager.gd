extends Node

## Top-level app state machine. Manages transitions between main menu and
## in-project states, holds settings, and owns the active UI panel.

@onready var project_manager = %ProjectManager
@onready var project_space: Node3D = %ProjectSpace
@onready var interaction = %Interaction
@onready var left_controller: XRController3D = %LeftController
@onready var right_controller: XRController3D = %RightController
@onready var xr_camera: XRCamera3D = %XRCamera3D

enum AppState { MAIN_MENU, IN_PROJECT }
var state: AppState = AppState.MAIN_MENU

var settings := SettingsData.new()
var active_panel: XRPanel = null


func _ready() -> void:
	settings.load_from_file()
	# Apply settings to project manager
	project_manager.max_undo_steps = settings.max_undo_steps
	project_manager.export_directory = settings.export_directory

	# Hide project space and action areas until a project is opened
	project_space.visible = false
	interaction.set_action_areas_visible(false)

	# Start at main menu
	_enter_main_menu()


# --- State transitions ---

const DEFAULT_PROJECT_OFFSET := Vector3(0.0, 0.5, -0.75)

func open_project(dir_name: String) -> void:
	_destroy_active_panel()
	project_manager.open_project(dir_name)
	project_space.visible = true
	project_space.transform = Transform3D(Basis.IDENTITY, DEFAULT_PROJECT_OFFSET)
	state = AppState.IN_PROJECT

	interaction.set_action_areas_visible(true)
	interaction.set_mode(interaction.Mode.SIZE)

	_create_in_project_panel()


func create_and_open_project() -> void:
	_destroy_active_panel()
	project_manager.create_new_project()
	project_space.visible = true
	project_space.transform = Transform3D(Basis.IDENTITY, DEFAULT_PROJECT_OFFSET)
	state = AppState.IN_PROJECT
	interaction.set_action_areas_visible(true)
	interaction.set_mode(interaction.Mode.SIZE)
	_create_in_project_panel()


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
	panel.reset_position(xr_camera, "center")
	active_panel = panel


func _create_in_project_panel() -> void:
	var panel := InProjectPanel.create_panel(self)
	add_child(panel)
	panel.setup(left_controller, right_controller)
	panel.reset_position(xr_camera, settings.panel_side)
	active_panel = panel


func _destroy_active_panel() -> void:
	if active_panel and is_instance_valid(active_panel):
		active_panel.queue_free()
		active_panel = null


## Reposition the active panel in front of the camera.
func reset_panel_position() -> void:
	if active_panel and is_instance_valid(active_panel):
		var side := settings.panel_side if state == AppState.IN_PROJECT else "center"
		active_panel.reset_position(xr_camera, side)


## Show a popup in front of the camera.
func show_popup(text: String, color: Color = Color.WHITE, dismiss_time: float = 30.0) -> XRPopup:
	var popup := XRPopup.create(text, color, dismiss_time)
	get_tree().root.add_child(popup)
	popup.setup(left_controller, right_controller)
	popup.reset_position(xr_camera, "center")
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
	project_manager.export_directory = settings.export_directory
