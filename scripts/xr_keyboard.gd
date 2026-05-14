class_name XRKeyboard
extends XRPanel

## In-VR virtual keyboard. SubViewport-rendered Control UI on a 3D quad, driven
## by the inherited XRPanel raycast + trigger-click pipeline. Subclasses override
## _build_keys() to provide a key layout.

signal dismissed
signal cancelled

## The control we send edits to. May be a LineEdit directly, or for the numpad
## variant a SpinBox (whose internal LineEdit will be used).
var target_control: Control = null

const BTN_FONT_SIZE := 22
const BTN_MIN_HEIGHT := 44

# Snapshot of the target's text at open time, restored on Cancel.
var _initial_text: String = ""


func _ready() -> void:
	super._ready()
	_build_background()
	_build_keys()
	_snapshot_and_position_caret()


# Subclasses override to fill in their key layout.
func _build_keys() -> void:
	pass


func _build_background() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.9)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", style)

	content_root.add_child(panel)


## The root inside the background panel where subclasses add their key grid.
func _layout_root() -> Control:
	# Returns the PanelContainer added in _build_background; subclasses add a
	# MarginContainer + VBox inside it.
	return content_root.get_child(0)


## Resolve the actual LineEdit we edit, whether target_control is a LineEdit or
## a SpinBox.
func _line_edit() -> LineEdit:
	if target_control is LineEdit:
		return target_control as LineEdit
	if target_control is SpinBox:
		return (target_control as SpinBox).get_line_edit()
	return null


func _snapshot_and_position_caret() -> void:
	var le := _line_edit()
	if le:
		_initial_text = le.text
		le.caret_column = le.text.length()


# --- Editing operations ---

## Insert a literal string at the current caret position.
func _insert(text: String) -> void:
	var le := _line_edit()
	if not le:
		return
	if le.has_selection():
		var from := le.get_selection_from_column()
		var to := le.get_selection_to_column()
		le.delete_text(from, to)
		le.caret_column = from
	le.insert_text_at_caret(text)


## Delete one character to the left of the caret (or the selection).
func _backspace() -> void:
	var le := _line_edit()
	if not le:
		return
	if le.has_selection():
		var from := le.get_selection_from_column()
		var to := le.get_selection_to_column()
		le.delete_text(from, to)
		le.caret_column = from
		return
	var col := le.caret_column
	if col > 0:
		le.delete_text(col - 1, col)
		le.caret_column = col - 1


## Commit the current value (fires text_submitted on LineEdit, value commit on
## SpinBox via release_focus) and dismiss.
func _commit_and_close() -> void:
	var le := _line_edit()
	if le:
		if target_control is LineEdit:
			le.text_submitted.emit(le.text)
		le.release_focus()
	_close()


func _close() -> void:
	dismissed.emit()


## Revert the target's text to what it was when the keyboard opened, then dismiss
## without emitting text_submitted (so no rename / no path save fires).
func _cancel() -> void:
	var le := _line_edit()
	if le:
		le.text = _initial_text
		le.caret_column = _initial_text.length()
		# release_focus on SpinBox's inner LineEdit re-parses the restored text
		# into the SpinBox value, which is a no-op since we never committed a change.
		le.release_focus()
	cancelled.emit()
	_close()


# --- Helpers for subclasses ---

func _make_key(label: String, parent: Control, expand: bool = false) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.add_theme_font_size_override("font_size", BTN_FONT_SIZE)
	btn.custom_minimum_size = Vector2(0, BTN_MIN_HEIGHT)
	btn.focus_mode = Control.FOCUS_NONE  # keyboard buttons must not steal focus
	if expand:
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(btn)
	return btn
