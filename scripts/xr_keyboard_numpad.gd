class_name XRKeyboardNumpad
extends XRKeyboard

## Numeric keypad for SpinBox / numeric LineEdit input. 4x4 grid: digits 1-9 in
## phone layout (7-8-9 top), 0 + decimal + minus on the bottom row, with
## Backspace/Enter/Close in the rightmost column. Minus is enabled only when
## the target SpinBox allows negatives; decimal only when step < 1.

const KEYBOARD_UI_SCENE := preload("res://scenes/ui/xr_keyboard_numpad_ui.tscn")

static func create_panel(target: Control) -> XRKeyboardNumpad:
	var kb := XRKeyboardNumpad.new()
	kb.panel_size = Vector2(360, 360)
	kb.pixel_size = 0.0008
	kb.target_control = target
	return kb


func _build_keys() -> void:
	var ui := KEYBOARD_UI_SCENE.instantiate() as Control
	_layout_root().add_child(ui)

	var allow_minus := true
	var allow_decimal := true
	if target_control is SpinBox:
		var sb := target_control as SpinBox
		allow_minus = sb.min_value < 0.0
		allow_decimal = sb.step < 1.0

	for digit in range(10):
		var digit_btn := ui.find_child("Digit%d" % digit, true, false) as Button
		digit_btn.pressed.connect(_insert.bind(str(digit)))

	var bksp_btn := ui.find_child("BackspaceButton", true, false) as Button
	bksp_btn.pressed.connect(_backspace)

	var enter_btn := ui.find_child("EnterButton", true, false) as Button
	enter_btn.pressed.connect(_commit_and_close)

	var cancel_btn := ui.find_child("CancelButton", true, false) as Button
	cancel_btn.pressed.connect(_cancel)

	var minus_btn := ui.find_child("MinusButton", true, false) as Button
	minus_btn.disabled = not allow_minus
	minus_btn.pressed.connect(_on_minus_pressed)

	var dot_btn := ui.find_child("DecimalButton", true, false) as Button
	dot_btn.disabled = not allow_decimal
	dot_btn.pressed.connect(_on_decimal_pressed)

	var clear_btn := ui.find_child("ClearButton", true, false) as Button
	clear_btn.pressed.connect(_on_clear_pressed)


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
