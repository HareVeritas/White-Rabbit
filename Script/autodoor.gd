extends Node3D

@export var open_height: float = 10.0
@export var closed_height: float = 0.0
@export var speed: float = 6.0   # units per second

var bodies_entered: int = 0


func enter_trigger(body: Node3D) -> void:
	if body is CharacterBody3D:
		bodies_entered += 1


func exit_trigger(body: Node3D) -> void:
	if body is CharacterBody3D:
		bodies_entered = maxi(bodies_entered - 1, 0)


func _process(delta: float) -> void:
	var target: float = open_height if bodies_entered > 0 else closed_height
	$StaticBody3D.position.y = move_toward($StaticBody3D.position.y, target, speed * delta)
