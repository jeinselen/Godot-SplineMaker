class_name Haptics
extends RefCounted

## Controller haptic feedback in one place: the pulse call shape and the "haptic"
## action name live here; the strengths/durations live in SettingsData. Callers
## express intent — tap or buzz — not the five-argument pulse incantation.
##
## "Tap"  = a single confirming click (intersecting a panel, a discrete action).
## "Buzz" = a lighter continuous tick (ongoing feedback while a gesture runs).

const ACTION := "haptic"


static func tap(controller: XRController3D) -> void:
	if controller:
		controller.trigger_haptic_pulse(
			ACTION, 0.0,
			SettingsData.HAPTIC_TAP_AMPLITUDE, SettingsData.HAPTIC_TAP_DURATION, 0.0)


static func buzz(controller: XRController3D) -> void:
	if controller:
		controller.trigger_haptic_pulse(
			ACTION, 0.0,
			SettingsData.HAPTIC_BUZZ_AMPLITUDE, SettingsData.HAPTIC_BUZZ_DURATION, 0.0)
