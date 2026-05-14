class_name XRKeyboardQWERTY
extends XRKeyboard

## Full text-input keyboard: digits row, QWERTY letters with latched Shift, and
## filesystem-safe symbols (dash, underscore, period) always visible.

const ROW_DIGITS := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
const ROW_TOP := ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"]
const ROW_MID := ["a", "s", "d", "f", "g", "h", "j", "k", "l"]
const ROW_BOT := ["z", "x", "c", "v", "b", "n", "m"]
const ROW_SYMS := ["-", "_", "."]

var _shift: bool = false
var _shift_btn: Button = null
var _letter_buttons: Array[Button] = []


static func create_panel(target: Control) -> XRKeyboardQWERTY:
	var kb := XRKeyboardQWERTY.new()
	kb.panel_size = Vector2(640, 320)
	kb.pixel_size = 0.0007
	kb.target_control = target
	return kb


func _build_keys() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layout_root().add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	_add_letter_row(vbox, ROW_DIGITS, false)
	_add_letter_row(vbox, ROW_TOP, true)
	_add_letter_row(vbox, ROW_MID, true)

	var bottom_row := HBoxContainer.new()
	bottom_row.add_theme_constant_override("separation", 4)
	vbox.add_child(bottom_row)
	for ch in ROW_BOT:
		var btn := _make_key(ch, bottom_row, true)
		_letter_buttons.append(btn)
		btn.pressed.connect(_on_letter_pressed.bind(btn))
	for sym in ROW_SYMS:
		var sbtn := _make_key(sym, bottom_row, true)
		sbtn.pressed.connect(_on_literal_pressed.bind(sym))

	var ctrl_row := HBoxContainer.new()
	ctrl_row.add_theme_constant_override("separation", 4)
	vbox.add_child(ctrl_row)

	_shift_btn = _make_key("Shift", ctrl_row, true)
	_shift_btn.toggle_mode = true
	_shift_btn.toggled.connect(_on_shift_toggled)

	var space_btn := _make_key("Space", ctrl_row, true)
	space_btn.size_flags_stretch_ratio = 3.0
	space_btn.pressed.connect(_on_literal_pressed.bind(" "))

	var bksp_btn := _make_key("Bksp", ctrl_row, true)
	bksp_btn.pressed.connect(_backspace)

	var enter_btn := _make_key("Enter", ctrl_row, true)
	enter_btn.pressed.connect(_commit_and_close)

	var cancel_btn := _make_key("Cancel", ctrl_row, true)
	cancel_btn.pressed.connect(_cancel)


func _add_letter_row(parent: Control, chars: Array, is_letter: bool) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)
	for ch in chars:
		var btn := _make_key(ch, row, true)
		if is_letter:
			_letter_buttons.append(btn)
			btn.pressed.connect(_on_letter_pressed.bind(btn))
		else:
			btn.pressed.connect(_on_literal_pressed.bind(ch))


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
