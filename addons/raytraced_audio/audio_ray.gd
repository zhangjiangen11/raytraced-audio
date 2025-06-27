extends RayCast3D

const RaytracedAudioListener: Script = preload("res://addons/raytraced_audio/raytraced_audio_listener.gd")
const RaytracedAudioPlayer3D: Script = preload("res://addons/raytraced_audio/raytraced_audio_player_3d.gd")

var cast_dist: float = 0.0
var max_bounces: int = 1

var echo_dist: float = 0.0
var echo_count: int = 0
var bounces: int = 0
var has_bounced_this_tick: bool = false
var escaped: bool = false
var escape_dir: Vector3 = Vector3.ZERO

var _space_state: PhysicsDirectSpaceState3D


func _init(raycast_dist: float, max_bounce_count: int) -> void:
	top_level = true
	enabled = false
	cast_dist = raycast_dist
	max_bounces = max_bounce_count


func _enter_tree() -> void:
	owner = get_parent()
	assert(owner is RaytracedAudioListener)


func _ready() -> void:
	_space_state = get_world_3d().direct_space_state
	reset()


# TODO: optimize
func update():
	# Reset if needed
	if escaped or bounces > max_bounces:
		reset()

	force_raycast_update()
	bounces += 1

	# Escaped outside
	if !is_colliding():
		escaped = true
		return

	# Bounce
	var hit_pos: Vector3 = get_collision_point()
	var normal: Vector3 = get_collision_normal()
	global_position = hit_pos + normal * 0.1
	target_position = target_position.bounce(normal)
	has_bounced_this_tick = true

	# Lowpass filter ray: Check for line of sight with audio players
	for player: RaytracedAudioPlayer3D in get_tree().get_nodes_in_group(RaytracedAudioPlayer3D.ENABLED_GROUP_NAME):
		var has_line_of_sight: bool = _cast_ray(player.global_position).is_empty()
		player.lowpass_rays_count += int(has_line_of_sight)
		# Same as:
		# if has_line_of_sight:
		# 	player.lowpass_rays_count += 1

	# Echo ray: Check for line of light with listener
	# Optimization: no need to raycast for first echo bounce
	if bounces > 1 and !_cast_ray(owner.global_position).is_empty():
		return
	# The way is clear -> echo
	var dist: float = hit_pos.distance_to(owner.global_position)
	echo_dist += dist
	echo_count += 1
	escape_dir = owner.global_position.direction_to(hit_pos)


## Return to the listener with a random direction
func reset():
	var pitch: float = randf_range(0.0, TAU)
	var yaw: float = randf_range(0.0, TAU)
	var dir: Vector3 = Vector3.FORWARD\
		.rotated(Vector3.RIGHT, pitch)\
		.rotated(Vector3.UP, yaw)
	
	global_position = owner.global_position
	target_position = dir * cast_dist

	bounces = 0
	escaped = false
	escape_dir = dir
	reset_tick_stats()


func reset_tick_stats() -> void:
	has_bounced_this_tick = false
	echo_dist = 0.0
	echo_count = 0


func _cast_ray(to: Vector3) -> Dictionary:
	var params: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		global_position,
		to,
		0b01
	)
	return _space_state.intersect_ray(params)
