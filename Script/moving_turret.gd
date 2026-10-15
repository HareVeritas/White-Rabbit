extends CharacterBody3D
## Ranged turret: only the HEAD tracks the player; the body rolls on its ball
## foot to keep a comfortable distance.
##
## EXPECTED NODES (matches your MovingTurret scene):
##   MovingTurret (this script)
##       AnimationPlayer      <- fine to keep; see the animation notes below
##       CollisionShape3D
##       model / head (with a "barrel" node inside it), wheel, body
##       RayCast3D            <- leave "Exclude Parent" ON
##
## The player must be in the "player" group (lowercase). The script also adds
## the player's collision layer to the ray's mask, so layers can't hide you.
##
## BARREL AIMING: the script looks at the meshes under the "barrel" node,
## finds the barrel's long axis and which end is the muzzle, and rotates the
## head so THAT direction points at the player. This works even if the barrel
## is mounted on the side of the head, or the model faces +Z / +X.
##
## ANIMATION NOTES: this script only writes the head's ROTATION. Animations
## that key the head's position (recoil) or the barrel / body / model are fine.
## Don't key the head's rotation in an animation or the two will fight.
## (head_overridden=true in the debug line means something is doing that.)

@export_group("Movement")
@export var speed: float = 4.0
@export var acceleration: float = 12.0
@export var gravity: float = 24.0
@export var attack_range: float = 12.0   # moves closer if the player is farther than this
@export var min_range: float = 8.0       # backs away if the player is closer than this

@export_group("Head Aim")
@export var head_turn_speed: float = 8.0
@export var min_pitch_deg: float = 0.0  # negative = allowed to look down
@export var max_pitch_deg: float = 45.0
@export var aim_offset: Vector3 = Vector3(0.0, 0.5, 0.0)  # point on the player to aim at
@export var yaw_offset_deg: float = 0.0   # small manual trim if it's still slightly off
## Head-local direction the barrel points. Leave at (0,0,0) to auto-detect.
## If auto-detect picks wrong, try (0,0,-1), (0,0,1), (1,0,0) or (-1,0,0).
@export var barrel_direction_override: Vector3 = Vector3.ZERO

@export_group("Wheel")
@export var ball_radius: float = 0.5     # match your sphere's radius

@export_group("Debug")
@export var debug_print: bool = true     # prints a status line once per second

@onready var head: Node3D = $head2
@onready var ball_foot: Node3D = $wheel2
@onready var ray_cast: RayCast3D = $RayCast3D
@onready var anim_tree: AnimationTree = $AnimationTree
@onready var anim: AnimationPlayer = $AnimationPlayer

@export var max_health: float = 60.0
var health: float


func _ready() -> void:
	_calibrate_barrel()      # keep your existing line
	health = max_health
	add_to_group("enemies")
	anim.play("idle")


func take_damage(amount: float, _from_direction: Vector3) -> void:
	health -= amount
	if health <= 0.0:
		queue_free()         # swap for a death animation later
		return
	anim_tree.set("parameters/HurtOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)   # go back to idling after the hurt animation


func shoot() -> void:
	anim_tree.set("parameters/ShootOneShot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func on_grabbed(_by: Node3D) -> void:
	pass  # player.gd calls this on anything in the "enemies" group

var player: Node3D = null
var can_see_player: bool = false

var _barrel_dir: Vector3 = Vector3(0.0, 0.0, -1.0)   # head-local direction of the muzzle
var _barrel_fix: Quaternion = Quaternion.IDENTITY
var _has_aimed: bool = false
var _last_q: Quaternion = Quaternion.IDENTITY
var _head_overridden: bool = false
var _debug_timer: float = 0.0


# ============================================================
#  BARREL CALIBRATION
# ============================================================
func _calibrate_barrel() -> void:
	if barrel_direction_override != Vector3.ZERO:
		_barrel_dir = barrel_direction_override.normalized()
	else:
		_barrel_dir = _detect_barrel_direction()
	_barrel_fix = _make_fix(_barrel_dir)


func _detect_barrel_direction() -> Vector3:
	var barrel := head.find_child("barrel", true, false)
	if barrel == null:
		push_warning("MovingTurret: no node named 'barrel' under head; assuming it points along -Z.")
		return Vector3(0.0, 0.0, -1.0)

	var meshes: Array = barrel.find_children("*", "MeshInstance3D", true, false)
	if barrel is MeshInstance3D:
		meshes.append(barrel)

	var to_head := head.global_transform.affine_inverse()
	var best_len: float = 0.0
	var best_dir := Vector3(0.0, 0.0, -1.0)

	for node in meshes:
		var mi := node as MeshInstance3D
		var box := mi.get_aabb()
		var rel: Transform3D = to_head * mi.global_transform
		var c := box.get_center()
		for i in 3:
			var axis := Vector3.ZERO
			axis[i] = 1.0
			var half := axis * (box.size[i] * 0.5)
			var a := rel * (c - half)
			var b := rel * (c + half)
			var length := a.distance_to(b)
			if length > best_len:
				best_len = length
				var dir := (b - a).normalized()
				# The muzzle is the end that sits farther from the head's pivot.
				if a.length() > b.length():
					dir = -dir
				best_dir = dir
	return best_dir


func _make_fix(d: Vector3) -> Quaternion:
	# A rotation that maps the barrel's direction onto the node's -Z "forward",
	# so we can aim -Z at the player and have the barrel follow.
	var forward := Vector3(0.0, 0.0, -1.0)
	if d.dot(forward) < -0.9999:
		return Quaternion(Vector3.UP, PI)
	return Quaternion(forward, d).inverse()


# ============================================================
#  MAIN LOOP
# ============================================================
func _physics_process(delta: float) -> void:
	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta
	else:
		velocity.y = 0.0

	# Find the player (retries every frame until it exists)
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group("player")
		# Make sure the ray scans whatever layer the player is on.
		var body := player as CollisionObject3D
		if body:
			ray_cast.collision_mask |= body.collision_layer

	var target_velocity := Vector3.ZERO
	can_see_player = false

	if player:
		can_see_player = _check_line_of_sight()
		if can_see_player:
			_aim_head(delta)
			target_velocity = _desired_velocity()

	velocity.x = move_toward(velocity.x, target_velocity.x, acceleration * delta)
	velocity.z = move_toward(velocity.z, target_velocity.z, acceleration * delta)
	move_and_slide()

	_roll_ball_foot(delta)
	_debug(delta)


func _aim_point() -> Vector3:
	return player.global_position + aim_offset


func _check_line_of_sight() -> bool:
	ray_cast.global_position = head.global_position
	var to_player := _aim_point() - ray_cast.global_position
	# Extend the ray 1m past the player so it always passes through their body.
	var end := ray_cast.global_position + to_player.normalized() * (to_player.length() + 1.0)
	ray_cast.target_position = ray_cast.to_local(end)
	ray_cast.force_raycast_update()
	if not ray_cast.is_colliding():
		return false
	var hit := ray_cast.get_collider() as Node
	if hit == null:
		return false
	return hit == player or player.is_ancestor_of(hit) or hit.is_in_group("player")


func _desired_velocity() -> Vector3:
	var flat := player.global_position - global_position
	flat.y = 0.0
	var dist := flat.length()
	if dist < 0.001:
		return Vector3.ZERO
	var dir := flat / dist
	if dist < min_range:
		return -dir * speed        # too close: back away
	elif dist > attack_range:
		return dir * speed         # too far: close in
	return Vector3.ZERO            # ideal range: hold position


func _aim_head(delta: float) -> void:
	# Work in the head's parent space (the "model" node) so the body never
	# rotates, only the head does.
	var parent := head.get_parent() as Node3D
	var local_target: Vector3 = parent.to_local(_aim_point())
	var dir := local_target - head.position

	var yaw := atan2(-dir.x, -dir.z) + deg_to_rad(yaw_offset_deg)   # -Z is "forward"
	var pitch := atan2(dir.y, Vector2(dir.x, dir.z).length())
	pitch = clampf(pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))

	# Aim -Z at the player, then rotate by the barrel fix so the BARREL (not -Z)
	# is what ends up pointing at the player.
	var target_q := Quaternion.from_euler(Vector3(pitch, yaw, 0.0)) * _barrel_fix

	# If the head isn't where we left it last frame, something else (usually an
	# AnimationPlayer track on the head's rotation) is rewriting it.
	_head_overridden = _has_aimed and head.quaternion.angle_to(_last_q) > 0.02

	var t := clampf(head_turn_speed * delta, 0.0, 1.0)
	head.quaternion = head.quaternion.slerp(target_q, t)
	_last_q = head.quaternion
	_has_aimed = true


func _roll_ball_foot(delta: float) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var move_speed := horizontal.length()
	if move_speed > 0.01:
		var roll_axis := Vector3.UP.cross(horizontal.normalized())
		ball_foot.rotate(roll_axis, (move_speed / ball_radius) * delta)


# ============================================================
#  DEBUG
# ============================================================
func _debug(delta: float) -> void:
	if not debug_print:
		return
	_debug_timer += delta
	if _debug_timer < 1.0:
		return
	_debug_timer = 0.0
	if player == null:
		print("[Turret] NO PLAYER FOUND (is the player node in the 'player' group?)")
		return
	var barrel_world := (head.global_transform.basis * _barrel_dir).normalized()
	var to_target := (_aim_point() - head.global_position).normalized()
	var aim_err := rad_to_deg(barrel_world.angle_to(to_target))
	var flat := player.global_position - global_position
	flat.y = 0.0
	print("[Turret] sees_player=", can_see_player,
		" | dist=", snappedf(flat.length(), 0.1),
		" | barrel_dir=", _barrel_dir.snapped(Vector3(0.01, 0.01, 0.01)),
		" | aim_error_deg=", snappedf(aim_err, 0.1),
		" | head_overridden=", _head_overridden)
