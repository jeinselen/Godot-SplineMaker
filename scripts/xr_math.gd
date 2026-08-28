class_name XRMath
extends RefCounted

## Shared XR placement math — one definition of "in front of the user" so panels
## and the project space can't drift apart.


## A yaw-aligned, gravity-aligned transform placed in front of the camera on the
## horizontal plane. `offset` is camera-relative: X = the user's right, Y = up
## (true vertical), Z = forward (the direction the user faces, projected onto the
## horizontal plane — head pitch/roll ignored). The returned basis is upright and
## yawed to face the user: its -Z points forward (away from the user), so a
## +Z-facing QuadMesh shows its front, and a container laid out along -Z faces
## forward. Guards a straight-up/down gaze from collapsing the horizontal vector.
static func frame_in_front(camera: XRCamera3D, offset: Vector3) -> Transform3D:
	var cam_t := camera.global_transform
	var cam_forward := -cam_t.basis.z
	var forward := Vector3(cam_forward.x, 0.0, cam_forward.z)
	if forward.length() < 0.0001:
		forward = Vector3(0.0, 0.0, -1.0)
	forward = forward.normalized()
	var right := forward.cross(Vector3.UP)  # +X = the user's right
	var origin := cam_t.origin + right * offset.x + Vector3.UP * offset.y + forward * offset.z
	return Transform3D(Basis.looking_at(forward, Vector3.UP), origin)
