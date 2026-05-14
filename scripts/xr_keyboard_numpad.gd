class_name XRKeyboardNumpad
extends XRKeyboard

## Numeric keypad for SpinBox / numeric LineEdit input. 4x4 grid: digits 1-9 in
## phone layout (7-8-9 top), 0 + decimal + minus on the bottom row, with
## Backspace/Enter/Close in the rightmost column. Minus is enabled only when
## the target SpinBox allows negatives; decimal only when step < 1.

static func create_panel(target: Control) -> XRKeyboardNumpad:
	var kb := XRKeyboardNumpad.new()
	kb.panel_size = Vector2(360, 360)
	kb.pixel_size = 0.0008
	kb.target_control = target
	return kb


func _build_keys() -> void:
	var allow_minus := true
	var allow_decimal := true
	if target_control is SpinBox:
		var sb := target_control as SpinBox
		allow_minus = sb.min_value < 0.0
		allow_decimal = sb.step < 1.0

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layout_root().add_child(margin)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	margin.add_child(grid)

	# Row 1
	_digit(grid, "7")
	_digit(grid, "8")
	_digit(grid, "9")
	_make_key("Bksp", grid, true).pressed.connect(_backspace)

	# Row 2
	_digit(grid, "4")
	_digit(grid, "5")
	_digit(grid, "6")
	_make_key("Enter", grid, true).pressed.connect(_commit_and_close)

	# Row 3
	_digit(grid, "1")
	_digit(grid, "2")
	_digit(grid, "3")
	_make_key("Cancel", grid, true).pressed.connect(_cancel)

	# Row 4
	var minus_btn := _make_key("-", grid, true)
	minus_btn.disabled = not allow_minus
	minus_btn.pressed.connect(_on_minus_pressed)

	_digit(grid, "0")

	var dot_btn := _make_key(".", grid, true)
	dot_btn.disabled = not allow_decimal
	dot_btn.pressed.connect(_on_decimal_pressed)

	_make_key("Clear", grid, true).pressed.connect(_on_clear_pressed)


func _digit(parent: Control, ch: String) -> void:
	var btn := _make_key(ch, parent, true)
	btn.pressed.connect(_insert.bind(ch))


## Minus only meaningful at column 0; toggle if already present.
func _on_minus_pressed() -> void:
	var le := _line_edit()
	if not le:
		return
	if le.text.begins_with("-"):
		le.text = le.text.substr(1)
		le.caret_column = maxi(0, le.caret_column - 1)
	else:
		le.text = "-" + le.text
		le.caret_column += 1


## Only allow one decimal point in the field.
func _on_decimal_pressed() -> void:
	var le := _line_edit()
	if not le:
		return
	if le.text.contains("."):
		return
	_insert(".")


func _on_clear_pressed() -> void:
	var le := _line_edit()
	if not le:
		return
	le.text = ""
	le.caret_column = 0
