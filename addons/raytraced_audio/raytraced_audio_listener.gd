extends AudioListener3D

## TODO: documentation

# TODO: debugging tools
# TODO: make some members private
# TODO: signals

const SPEED_OF_SOUND: float = 343.0 # speed of sound in m/s
const GROUP_NAME: StringName = &"RaytracedAudioListener"

const AudioRay: Script = preload("res://addons/raytraced_audio/audio_ray.gd")
const RaytracedAudioPlayer3D: Script = preload("res://addons/raytraced_audio/raytraced_audio_player_3d.gd")
const RaytracedAudioListener: Script = preload("res://addons/raytraced_audio/raytraced_audio_listener.gd")

var rays: Array[AudioRay] = []


@export var is_enabled: bool = true:
	set(v):
		if is_enabled == v:
			return
		is_enabled = v

		if is_enabled:
			setup()
		else:
			clear()
@export var auto_update: bool = true:
	set(v):
		auto_update = v
		set_process(auto_update)

@export var rays_count: int = 4:
	set(v):
		if v == rays_count:
			return
		rays_count = maxi(v, 1)
		clear()
		setup()

@export var max_raycast_dist: float = SPEED_OF_SOUND:
	set(v):
		max_raycast_dist = v
		update_ray_configuration()
@export var max_bounces: int = 3:
	set(v):
		max_bounces = v
		update_ray_configuration()

@export_category("Muffle")
@export var muffle_enabled: bool = true
@export var muffle_interpolation: float = 0.01
@export_category("Echo")
@export var echo_enabled: bool = true
@export var echo_room_size_multiplier: float = 2.0
@export var echo_interpolation: float = 0.01
@export_category("Ambient")
@export var ambient_enabled: bool = true
@export var ambient_direction_interpolation: float = 0.02
@export var ambient_volume_interpolation: float = 0.01
@export var ambient_volume_attenuation: float = 0.998

var room_size: float = 0.0
var ambience: float = 0.0
var ambient_dir: Vector3 = Vector3.ZERO

var _reverb_effect: AudioEffectReverb
var _pan_effect: AudioEffectPanner


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	# Reverb effect
	var i: int = AudioServer.get_bus_index(ProjectSettings.get_setting("raytraced_audio/reverb_bus"))
	if i == -1:
		push_error("Failed to get reverb bus for raytraced audio. Disabling echo...")
		# TODO: disable echo
	else:
		_reverb_effect = AudioServer.get_bus_effect(i, 0)

	# Pan effect
	i = AudioServer.get_bus_index(ProjectSettings.get_setting("raytraced_audio/ambient_bus"))
	if i == -1:
		push_error("Failed to get ambient bus for raytraced audio. Disabling echo...")
		# TODO: disable ambient
	else:
		_pan_effect = AudioServer.get_bus_effect(i, 0)

	if is_enabled:
		setup()

	set_process(auto_update)
	if is_enabled:
		make_current()

	# TODO: debugging tools
	# Performance.add_custom_monitor(&"raycast_audio/ambience", func(): return ambience)
	# Performance.add_custom_monitor(&"raycast_audio/echo_room_size", func(): return room_size)
	


func setup() -> void:
	for __ in rays_count:
		var rc: AudioRay = AudioRay.new(max_raycast_dist, max_bounces)
		add_child(rc, INTERNAL_MODE_BACK)
		rays.push_back(rc)


func clear():
	for ray: AudioRay in rays:
		remove_child(ray)
		ray.queue_free()
	rays.clear()


func _process(delta: float) -> void:
	if !auto_update:
		set_process(false)
		return
	update()


func update():
	if !is_enabled:
		return

	var echo: float = 0.0 # Avg echo from all rays
	var echo_count: int = 0 # Number of echo rays that came back
	var bounces_this_tick: int = 0
	var escaped_count: int = 0
	var escaped_dir: Vector3 = Vector3.ZERO # Avg escape direction
	var escaped_strength: float = 0.0

	# Gather data
	for ray: AudioRay in rays:
		ray.update()

		echo += ray.echo_dist
		echo_count += ray.echo_count
		bounces_this_tick += int(ray.has_bounced_this_tick)

		if ray.escaped:
			escaped_count += 1
			escaped_strength += 1.0 / ray.bounces
			escaped_dir += ray.escape_dir

		ray.reset_tick_stats()
	
	echo = 0.0 if echo_count == 0 else (echo / float(echo_count))
	escaped_dir = Vector3.ZERO if escaped_count == 0 else (escaped_dir / float(escaped_count))

	if muffle_enabled:
		_update_muffle()
	if echo_enabled:
		_update_echo(echo, echo_count, bounces_this_tick)
	if ambient_enabled:
		_update_ambient(escaped_strength, escaped_dir)


func _update_muffle() -> void:
	for player: RaytracedAudioPlayer3D in get_tree().get_nodes_in_group(RaytracedAudioPlayer3D.GROUP_NAME):
		player.update(global_position, rays_count, muffle_interpolation)


func _update_echo(echo: float, echo_count: int, bounces: int) -> void:
	# Length -> echo delay
	room_size = lerpf(room_size, echo, echo_interpolation)
	var e: float = (room_size * echo_room_size_multiplier) / SPEED_OF_SOUND
	# print("e = ", e)
	_reverb_effect.room_size = lerpf(_reverb_effect.room_size, clampf(e, 0.0, 1.0), echo_interpolation)
	_reverb_effect.predelay_msec = lerpf(_reverb_effect.predelay_msec, e * 1000, echo_interpolation)
	_reverb_effect.predelay_feedback = lerpf(_reverb_effect.predelay_feedback, clampf(e, 0.0, 0.98), echo_interpolation)

	# More rays % -> echo strength
	var return_ratio: float = 0.0 if bounces == 0 else float(echo_count) / float(bounces)
	_reverb_effect.hipass = lerpf(_reverb_effect.hipass, 1.0 - return_ratio, echo_interpolation)


func _update_ambient(escaped_strength: float, escaped_dir: Vector3) -> void:
	var ambience_ratio: float = float(escaped_strength) / float(rays_count)

	# More rays % -> louder
	if escaped_strength > 0:
		ambience = lerpf(ambience, 1.0, ambience_ratio)
	else:
		ambience *= ambient_volume_attenuation
	var ambient_bus_idx: int = AudioServer.get_bus_index(ProjectSettings.get_setting("raytraced_audio/ambient_bus"))
	var volume: float = AudioServer.get_bus_volume_linear(ambient_bus_idx)
	AudioServer.set_bus_volume_linear(ambient_bus_idx, lerpf(volume, ambience, ambient_volume_interpolation))
	
	# Avg escape direction -> pan
	ambient_dir = ambient_dir.lerp(escaped_dir, ambient_direction_interpolation)
	var target_pan: float = 0.0 if ambient_dir.is_zero_approx() else owner.transform.basis.x.dot(ambient_dir.normalized())
	_pan_effect.pan = target_pan


func update_ray_configuration() -> void:
	for ray: AudioRay in rays:
		ray.cast_dist = max_raycast_dist
		ray.max_bounces = max_bounces
