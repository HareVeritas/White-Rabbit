extends CharacterBody3D
## Quake/Ultrakill-style movement + dual-hand punch/grab/smash combat.
## Godot 4.4.1
##
## REQUIRED NODE STRUCTURE (as children of this CharacterBody3D):
##   CollisionShape3D
##   Node3D                   <- head/look pivot
##       Camera3D              <- eye height, used for look + raycasts
##           Marker3D  "RightHandMarker"  (roughly bottom-right of view, local pos e.g. (0.4, -0.3, -0.6))
##           Marker3D  "LeftHandMarker"   (roughly bottom-left of view,  local pos e.g. (-0.4, -0.3, -0.6))
##
## REQUIRED INPUT MAP ACTIONS (Project Settings > Input Map):
##   move_forward, move_back, move_left, move_right
##   jump         -> Space. Launches immediately on press; hold it through the
##                   rise for full height, release early for a short hop —
##                   see Bunny Hop group (jump_velocity, jump_cut_multiplier).
##   sprint       -> Left Shift (hold)
##   punch_left   -> Mouse Button Left
##   punch_right  -> Mouse Button Right
##   grab_right   -> E
##   grab_left    -> Q
##
## ENEMY CONTRACT: anything you want to be punchable/grabbable should be in the
## "enemies" group and implement (see enemy_example.gd):
##   take_damage(amount: float, from_direction: Vector3) -> void
##   on_grabbed(by: Node3D) -> void
##   on_second_hand_grabbed() -> void
##   on_released() -> void
##   get_grab_point() -> Vector3   (world position enemy should snap to while held)

enum Hand { LEFT, RIGHT }

# ---------------- Movement tuning (Quake-ish air control) ----------------
@export_group("Movement")
@export var ground_speed: float = 9.0
@export var air_speed_cap: float = 9.0          # max speed air-accel is allowed to add toward
@export var sprint_multiplier: float = 1.6      # applied to both ground_speed and air_speed_cap while held
@export var ground_accel: float = 14.0
@export var air_accel: float = 55.0             # high accel = strong air strafing, quake feel
@export var friction: float = 8.0
@export var gravity: float = 24.0

@export_group("Bunny Hop")
@export var jump_velocity: float = 26.0         # full jump launch velocity, applied instantly on press
@export var jump_cut_multiplier: float = 0.67   # fraction of upward velocity kept if you release early (0-1)
@export var bhop_jump_buffer: float = 0.12      # seconds a jump press is remembered before landing
@export var bhop_coyote_time: float = 0.1       # seconds after leaving ground you can still jump
@export var mouse_sensitivity: float = 0.0025
@export var max_pitch_deg: float = 89.0

@export_group("Head Bob")
@export var bob_enabled: bool = true
@export var bob_amplitude: float = 0.06         # vertical bob height, in meters
@export var bob_side_amplitude: float = 0.035   # horizontal sway, in meters
@export var bob_frequency: float = 2.2          # bob cycles per second at ground_speed
@export var bob_sprint_frequency_mult: float = 1.35
@export var bob_smoothing: float = 10.0         # how fast bob fades in/out and returns to center
@export var bob_min_speed: float = 0.5          # horizontal speed below which bobbing stops

# ---------------- Combat tuning ----------------
@export_group("Combat - Punching")
@export var punch_range: float = 2.5
@export var punch_damage_min: float = 8.0
@export var punch_damage_max: float = 35.0
@export var charge_time_max: float = 1.2        # seconds held to reach full charge
@export var punch_knockback_min: float = 4.0
@export var punch_knockback_max: float = 16.0

@export_group("Combat - Grabbing")
@export var grab_range: float = 3.5
@export var grab_cone_deg: float = 35.0         # how far off-center an enemy can be and still be grabbable

@export_group("Combat - Smashing")
@export var wall_check_distance: float = 1.6    # how close a wall must be, directly ahead, to allow wall smash
@export var clap_damage_min: float = 25.0
@export var clap_damage_max: float = 90.0
@export var wall_smash_damage_min: float = 30.0
@export var wall_smash_damage_max: float = 100.0

# ---------------- Internal state ----------------
@onready var camera: Camera3D = $Node3D/Camera3D
@onready var right_hand_marker: Marker3D = $Node3D/Camera3D/RightHandMarker
@onready var left_hand_marker: Marker3D = $Node3D/Camera3D/LeftHandMarker

var _charging: Dictionary = { Hand.LEFT: false, Hand.RIGHT: false }
var _charge_start_time: Dictionary = { Hand.LEFT: 0.0, Hand.RIGHT: 0.0 }

var _grabbed_enemy: Node3D = null
var _hand_holding: Dictionary = { Hand.LEFT: false, Hand.RIGHT: false }

var _camera_pitch: float = 0.0

var _camera_base_position: Vector3
var _bob_time: float = 0.0
var _bob_offset: Vector3 = Vector3.ZERO

var _jump_buffer_timer: float = 0.0
var _coyote_timer: float = 0.0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_camera_base_position = camera.position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_apply_look(event.relative)
		return

	if event.is_action_pressed("jump"):
		_jump_buffer_timer = bhop_jump_buffer
	elif event.is_action_released("jump"):
		_try_jump_cut()

	if event.is_action_pressed("punch_left"):
		_start_charge(Hand.LEFT)
	elif event.is_action_released("punch_left"):
		_release_charge(Hand.LEFT)

	if event.is_action_pressed("punch_right"):
		_start_charge(Hand.RIGHT)
	elif event.is_action_released("punch_right"):
		_release_charge(Hand.RIGHT)

	if event.is_action_pressed("grab_right"):
		_toggle_grab(Hand.RIGHT)
	if event.is_action_pressed("grab_left"):
		_toggle_grab(Hand.LEFT)


func _apply_look(mouse_delta: Vector2) -> void:
	rotate_y(-mouse_delta.x * mouse_sensitivity)
	_camera_pitch = clamp(
		_camera_pitch - mouse_delta.y * mouse_sensitivity,
		deg_to_rad(-max_pitch_deg),
		deg_to_rad(max_pitch_deg)
	)
	camera.rotation.x = _camera_pitch


func _try_jump_cut() -> void:
	# Variable jump height: releasing early while still rising trims the
	# upward velocity, so a quick tap gives a short hop and holding through
	# the rise gives the full-height jump. Has no effect once you're
	# already falling (velocity.y <= 0).
	if velocity.y > 0.0:
		velocity.y *= jump_cut_multiplier


func _physics_process(delta: float) -> void:
	_quake_move(delta)
	_update_held_enemy_position()
	if bob_enabled:
		_update_head_bob(delta)
	else:
		_bob_offset = Vector3.ZERO
	camera.position = _camera_base_position + _bob_offset


# ============================================================
#  MOVEMENT
# ============================================================
func _quake_move(delta: float) -> void:
	var input_dir := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back") - Input.get_action_strength("move_forward")
	).normalized()

	var body_basis := global_transform.basis
	var wish_dir := (body_basis.x * input_dir.x + body_basis.z * input_dir.y)
	wish_dir.y = 0.0
	wish_dir = wish_dir.normalized()

	# --- Jump buffering + coyote time so a press just before/after landing still counts ---
	_jump_buffer_timer = maxf(_jump_buffer_timer - delta, 0.0)

	var grounded := is_on_floor()
	if grounded:
		_coyote_timer = bhop_coyote_time
	else:
		_coyote_timer = maxf(_coyote_timer - delta, 0.0)

	var wants_jump: bool = _jump_buffer_timer > 0.0
	var can_jump: bool = grounded or _coyote_timer > 0.0

	if grounded:
		if wants_jump and can_jump:
			velocity.y = jump_velocity
			_jump_buffer_timer = 0.0
			_coyote_timer = 0.0
			# Skip ground friction entirely on the frame you re-jump — this is the
			# classic bhop trick: touching the floor for a single frame shouldn't
			# bleed off the speed you built up strafing in the air.
			_accelerate(wish_dir, ground_speed * _get_speed_multiplier(), ground_accel, delta)
		else:
			velocity.y = 0.0
			_ground_accelerate(wish_dir, delta)
	else:
		velocity.y -= gravity * delta
		if wants_jump and can_jump:
			# Coyote jump: left the ledge a moment ago but input still counts.
			velocity.y = jump_velocity
			_jump_buffer_timer = 0.0
			_coyote_timer = 0.0
		_air_accelerate(wish_dir, delta)

	move_and_slide()


func _get_speed_multiplier() -> float:
	return sprint_multiplier if Input.is_action_pressed("sprint") else 1.0


func _ground_accelerate(wish_dir: Vector3, delta: float) -> void:
	# Friction first
	var speed := Vector2(velocity.x, velocity.z).length()
	if speed > 0.0001:
		var drop := speed * friction * delta
		var new_speed: float = maxf(speed - drop, 0.0)
		var speed_scale: float = new_speed / speed
		velocity.x *= speed_scale
		velocity.z *= speed_scale

	_accelerate(wish_dir, ground_speed * _get_speed_multiplier(), ground_accel, delta)


func _air_accelerate(wish_dir: Vector3, delta: float) -> void:
	# Classic Quake air-strafe accel, capped so you can't infinitely accelerate
	# in a straight line but CAN gain speed by strafing + mouse look.
	_accelerate(wish_dir, air_speed_cap * _get_speed_multiplier(), air_accel, delta)


func _accelerate(wish_dir: Vector3, wish_speed: float, accel: float, delta: float) -> void:
	if wish_dir == Vector3.ZERO:
		return
	var current_speed := Vector2(velocity.x, velocity.z).dot(Vector2(wish_dir.x, wish_dir.z))
	var add_speed := wish_speed - current_speed
	if add_speed <= 0.0:
		return
	var accel_speed: float = minf(accel * wish_speed * delta, add_speed)
	velocity.x += wish_dir.x * accel_speed
	velocity.z += wish_dir.z * accel_speed


func _update_head_bob(delta: float) -> void:
	var horizontal_speed := Vector2(velocity.x, velocity.z).length()
	var target_offset := Vector3.ZERO

	if is_on_floor() and horizontal_speed > bob_min_speed:
		var freq := bob_frequency
		if Input.is_action_pressed("sprint"):
			freq *= bob_sprint_frequency_mult
		var speed_ratio: float = clampf(horizontal_speed / ground_speed, 0.0, 1.5)

		_bob_time += delta * freq * speed_ratio * TAU
		# Vertical bounce twice per stride (footstep-like), lateral sway once per
		# stride so it traces a little figure-8 rather than a flat up/down pump.
		var vertical: float = absf(sin(_bob_time)) * bob_amplitude * speed_ratio
		var lateral: float = sin(_bob_time * 0.5) * bob_side_amplitude * speed_ratio
		target_offset = Vector3(lateral, vertical, 0.0)
	else:
		# Reset to a clean cycle start so the next step doesn't jerk mid-swing.
		_bob_time = 0.0

	_bob_offset = _bob_offset.lerp(target_offset, clampf(bob_smoothing * delta, 0.0, 1.0))


# ============================================================
#  PUNCH CHARGING
# ============================================================
func _start_charge(hand: int) -> void:
	_charging[hand] = true
	_charge_start_time[hand] = Time.get_ticks_msec() / 1000.0

	# Special case from your spec: if E+Q are already both held (both hands
	# gripping the same enemy) and you THEN start charging, allow the smash
	# to fire the instant charge begins building past a hair-trigger amount
	# is NOT what we want here — smash still resolves on release below, so
	# nothing else needs to happen at charge start.


func _release_charge(hand: int) -> void:
	if not _charging[hand]:
		return
	_charging[hand] = false
	var held_time: float = (Time.get_ticks_msec() / 1000.0) - float(_charge_start_time[hand])
	var ratio: float = clampf(held_time / charge_time_max, 0.0, 1.0)

	if _grabbed_enemy != null:
		if _hand_holding[Hand.LEFT] and _hand_holding[Hand.RIGHT]:
			_do_clap_smash(ratio)
		elif _check_wall_in_front():
			_do_wall_smash(ratio)
		else:
			_do_restrained_punch(hand, ratio)
	else:
		_do_free_punch(hand, ratio)


func _is_charging_any() -> bool:
	return _charging[Hand.LEFT] or _charging[Hand.RIGHT]


func _current_ratio(hand: int) -> float:
	if not _charging[hand]:
		return 0.0
	var held_time: float = (Time.get_ticks_msec() / 1000.0) - float(_charge_start_time[hand])
	return clampf(held_time / charge_time_max, 0.0, 1.0)


# ============================================================
#  FREE PUNCHING (no enemy grabbed)
# ============================================================
func _do_free_punch(_hand: int, ratio: float) -> void:
	var target := _raycast_forward(punch_range)
	if target == null or not target.is_in_group("enemies"):
		return
	var dmg: float = lerp(punch_damage_min, punch_damage_max, ratio)
	var kb: float = lerp(punch_knockback_min, punch_knockback_max, ratio)
	var dir := -camera.global_transform.basis.z
	target.take_damage(dmg, dir)
	if target.has_method("apply_knockback"):
		target.apply_knockback(dir * kb)


func _do_restrained_punch(_hand: int, ratio: float) -> void:
	# Free hand hitting an enemy that's being held by the other hand:
	# bonus damage, no real knockback since they're restrained.
	var dmg: float = lerp(punch_damage_min, punch_damage_max, ratio) * 1.5
	_grabbed_enemy.take_damage(dmg, -camera.global_transform.basis.z)


# ============================================================
#  GRABBING
# ============================================================
func _toggle_grab(hand: int) -> void:
	if _hand_holding[hand]:
		_release_hand(hand)
		return

	if _grabbed_enemy == null:
		var target := _find_grabbable_enemy()
		if target == null:
			return
		_grabbed_enemy = target
		_hand_holding[hand] = true
		target.on_grabbed(self)
	else:
		# Already holding something with the other hand — attach this hand
		# too, as long as the enemy is still within grab range.
		if global_position.distance_to(_grabbed_enemy.global_position) <= grab_range:
			_hand_holding[hand] = true
			if _grabbed_enemy.has_method("on_second_hand_grabbed"):
				_grabbed_enemy.on_second_hand_grabbed()

			# Both hands now full: if a mouse button happens to already be
			# charging at this moment, resolve the clap smash immediately
			# instead of waiting for release.
			if _hand_holding[Hand.LEFT] and _hand_holding[Hand.RIGHT] and _is_charging_any():
				var active_hand := Hand.LEFT if _charging[Hand.LEFT] else Hand.RIGHT
				var ratio := _current_ratio(active_hand)
				_charging[active_hand] = false
				_do_clap_smash(ratio)


func _release_hand(hand: int) -> void:
	_hand_holding[hand] = false
	if not _hand_holding[Hand.LEFT] and not _hand_holding[Hand.RIGHT]:
		if _grabbed_enemy and _grabbed_enemy.has_method("on_released"):
			_grabbed_enemy.on_released()
		_grabbed_enemy = null


func _find_grabbable_enemy() -> Node3D:
	var space_state := get_world_3d().direct_space_state
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z

	var best: Node3D = null
	var best_dot := cos(deg_to_rad(grab_cone_deg))

	for enemy in get_tree().get_nodes_in_group("enemies"):
		if not enemy is Node3D:
			continue
		var to_enemy: Vector3 = enemy.global_position - origin
		var dist := to_enemy.length()
		if dist > grab_range or dist <= 0.001:
			continue
		var dot := forward.dot(to_enemy.normalized())
		if dot < best_dot:
			continue
		# line-of-sight check
		var query := PhysicsRayQueryParameters3D.create(origin, enemy.global_position)
		query.exclude = [self]
		var hit := space_state.intersect_ray(query)
		if hit and hit.collider != enemy:
			continue
		best_dot = dot
		best = enemy
	return best


func _update_held_enemy_position() -> void:
	if _grabbed_enemy == null:
		return
	var target_point: Vector3
	if _hand_holding[Hand.LEFT] and _hand_holding[Hand.RIGHT]:
		target_point = (right_hand_marker.global_position + left_hand_marker.global_position) * 0.5
	elif _hand_holding[Hand.RIGHT]:
		target_point = right_hand_marker.global_position
	else:
		target_point = left_hand_marker.global_position

	if _grabbed_enemy.has_method("set_held_position"):
		_grabbed_enemy.set_held_position(target_point)
	else:
		_grabbed_enemy.global_position = target_point


# ============================================================
#  SMASHING
# ============================================================
func _check_wall_in_front() -> bool:
	var space_state := get_world_3d().direct_space_state
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + forward * wall_check_distance
	)
	query.exclude = [self, _grabbed_enemy]
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return false
	# Ignore hitting another enemy/prop; we want a static obstruction (wall/floor/etc).
	var collider = hit.collider
	if collider.is_in_group("enemies"):
		return false
	return true


func _do_clap_smash(ratio: float) -> void:
	if _grabbed_enemy == null:
		return
	var dmg: float = lerp(clap_damage_min, clap_damage_max, ratio)
	_grabbed_enemy.take_damage(dmg, Vector3.ZERO)
	if _grabbed_enemy.has_method("on_smashed"):
		_grabbed_enemy.on_smashed("clap", dmg)
	_release_hand(Hand.LEFT)
	_release_hand(Hand.RIGHT)


func _do_wall_smash(ratio: float) -> void:
	if _grabbed_enemy == null:
		return
	var dmg: float = lerp(wall_smash_damage_min, wall_smash_damage_max, ratio)
	var forward := -camera.global_transform.basis.z
	_grabbed_enemy.take_damage(dmg, forward)
	if _grabbed_enemy.has_method("on_smashed"):
		_grabbed_enemy.on_smashed("wall", dmg)
	if _grabbed_enemy.has_method("apply_knockback"):
		_grabbed_enemy.apply_knockback(forward * 20.0)
	var holding_hand := Hand.RIGHT if _hand_holding[Hand.RIGHT] else Hand.LEFT
	_release_hand(holding_hand)


# ============================================================
#  UTIL
# ============================================================
func _raycast_forward(max_dist: float) -> Node3D:
	var space_state := get_world_3d().direct_space_state
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + forward * max_dist)
	query.exclude = [self]
	var hit := space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	return hit.collider as Node3D
