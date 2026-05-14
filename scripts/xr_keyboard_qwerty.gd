class_name XRKeyboardQWERTY
extends XRKeyboard

## Full text-input keyboard: digits row, QWERTY letters with latched Shift, and
## filesystem-safe symbols (dash, underscore, period) always visible.

const ROW_SYMS := ["-", "_", "."]

var _shift: bool = false
var _shift_btn: Button = null
var _letter_buttons: Array[Button] = []

const KEYBOARD_UI_SCENE := preload("res://scenes/ui/xr_keyboard_qwerty_ui.tscn")


static func create_panel(target: Control) -> XRKeyboardQWERTY:
	var kb := XRKeyboardQWERTY.new()
	kb.panel_size = Vector2(640, 320)
	kb.pixel_size = 0.0007
	kb.target_control = target
	return kb


func _build_keys() -> void:
	var ui := KEYBOARD_UI_SCENE.instantiate() as Control
	_layout_root().add_child(ui)

	_connect_literal_row(ui.find_child("DigitsRow", true, false) as HBoxContainer)
	_connect_letter_row(ui.find_child("TopRow", true, false) as HBoxContainer)
	_connect_letter_row(ui.find_child("MidRow", true, false) as HBoxContainer)

	var bottom_row := ui.find_child("BottomRow", true, false) as HBoxContainer
	for btn in bottom_row.get_children():
		var key := btn as Button
		if not key:
			continue
		if key.text in ROW_SYMS:
			key.pressed.connect(_on_literal_pressed.bind(key.text))
		else:
			_letter_buttons.append(key)
			key.pressed.connect(_on_letter_pressed.bind(key))

	_shift_btn = ui.find_child("ShiftButton", true, false) as Button
	_shift_btn.toggled.connect(_on_shift_toggled)

	var space_btn := ui.find_child("SpaceButton", true, false) as Button
	space_btn.pressed.connect(_on_literal_pressed.bind(" "))

	var bksp_btn := ui.find_child("BackspaceButton", true, false) as Button
	bksp_btn.pressed.connect(_backspace)

	var enter_btn := ui.find_child("EnterButton", true, false) as Button
	enter_btn.pressed.connect(_commit_and_close)

	var cancel_btn := ui.find_child("CancelButton", true, false) as Button
	cancel_btn.pressed.connect(_cancel)


func _connect_literal_row(row: HBoxContainer) -> void:
	for child in row.get_children():
		var btn := child as Button
		if btn:
			btn.pressed.connect(_on_literal_pressed.bind(btn.text))


func _connect_letter_row(row: HBoxContainer) -> void:
	for child in row.get_children():
		var btn := child as Button
		if btn:
			_letter_buttons.append(btn)
			btn.pressed.connect(_on_letter_pressed.bind(btn))


func _on_letter_pressed(btn: Button) -> void:
	_insert(btn.text)
	# Shift acts as a one-shot capitaliser: drop it after the first letter so
	# the next keystroke is lowercase again.
	if _shift and _shift_btn:
		_shift_btn.button_pressed = false


func _on_literal_pressed(ch: String) -> void:
	_insert(ch)


func _on_shift_toggled(on: bool) -> void:
	_shift = on
	for btn in _letter_buttons:
		btn.text = btn.text.to_upper() if on else btn.text.to_lower()
