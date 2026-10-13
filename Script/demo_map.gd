extends Node3D
## Attach to the DemoMap root node. Wires up the scripted sequence:
##   room 1 dialogue ends -> door unlocks
##   room 2 dialogue ends -> enemy spawns
##
## Adjust the node paths below to match your actual scene tree.

@onready var room1_dialogue = $Triggers/Room1Dialogue
@onready var door = $Doors/autodoor
@onready var room2_dialogue = $Triggers/Room2Dialogue
@onready var enemy_spawner = $EnemySpawner


func _ready() -> void:
	door.lock()  # make sure it starts shut no matter what the Inspector says
	room1_dialogue.dialogue_finished.connect(door.unlock)
	room2_dialogue.dialogue_finished.connect(enemy_spawner.spawn)
