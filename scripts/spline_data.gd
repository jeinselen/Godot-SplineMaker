class_name SplineData
extends Resource

var order_u: int = 4
var resolution_u: int = 8
var cyclic: bool = false
var points: PackedVector3Array = PackedVector3Array()
var sizes: PackedFloat32Array = PackedFloat32Array()
var weights: PackedFloat32Array = PackedFloat32Array()


func add_point(position: Vector3, size: float = 0.1, weight: float = 1.0) -> void:
	points.append(position)
	sizes.append(size)
	weights.append(weight)


func point_count() -> int:
	return points.size()


## Returns the effective order, soft-clamped to the number of control points.
func effective_order() -> int:
	return mini(order_u, points.size())
