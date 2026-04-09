class_name XRPopup
extends XRPanel

## A small auto-dismissing popup panel for warnings, errors, and status messages.
## Extends XRPanel with a close button and optional auto-dismiss timer.

const DEFAULT_DISMISS_TIME := 30.0

var _dismiss_timer: float = 0.0
var _dismiss_duration: float = DEFAULT_DISMISS_TIME
var _label: Label
var _close_button: Button


## Create a popup with the given message, color, and optional auto-dismiss time.
## Call setup() after adding to the scene tree.
static func create(text: String, color: Color = Color.WHITE, dismiss_time: float = DEFAULT_DISMISS_TIME) -> XRPopup:
	var popup := XRPopup.new()
	popup.panel_size = Vector2(400, 200)
	popup._dismiss_duration = dismiss_time
	popup._setup_content(text, color)
	return popup


func _setup_content(text: String, color: Color) -> void:
	# Build UI in _ready after content_root is available
	# Store values for _ready
	set_meta("_popup_text", text)
	set_meta("_popup_color", color)


func _ready() -> void:
	super._ready()
	_build_ui()
	if _dismiss_duration > 0.0:
		_dismiss_timer = _dismiss_duration


func _build_ui() -> void:
	var text: String = get_meta("_popup_text", "")
	var color: Color = get_meta("_popup_color", Color.WHITE)

	var panel_container := PanelContainer.new()
	panel_container.set_anchors_preset(Control.PRESET_FULL_RECT)

	# Dark background
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.9)
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	panel_container.add_theme_stylebox_override("panel", style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	panel_container.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	_label = Label.new()
	_label.text = text
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_color_override("font_color", color)
	_label.add_theme_font_size_override("font_size", 22)
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_label)

	_close_button = Button.new()
	_close_button.text = "Close"
	_close_button.add_theme_font_size_override("font_size", 20)
	_close_button.pressed.connect(_on_close_pressed)
	vbox.add_child(_close_button)

	content_root.add_child(panel_container)


func _process(delta: float) -> void:
	super._process(delta)

	if _dismiss_duration > 0.0:
		_dismiss_timer -= delta
		if _dismiss_timer <= 0.0:
			queue_free()


func _on_close_pressed() -> void:
	queue_free()
