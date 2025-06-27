extends Node3D

## TODO: documentation

# TODO: debugging tools

const SPEED_OF_SOUND: float = 343.0 # speed of sound in m/s

const REVERB_BUS: StringName = &"RaytracedReverb"
const AMBIENT_BUS: StringName = &"RaytracedAmbient"

const AudioRay: Script = preload("res://addons/raytraced_audio/audio_ray.gd")
const RaytracedAudioPlayer3D: Script = preload("res://addons/raytraced_audio/raytraced_audio_player_3d.gd")

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
		rays_count = v

@export var max_raycast_dist: float = SPEED_OF_SOUND
@export var max_bounces: int = 3

@export_category("Muffle")
@export var muffle_interpolation: float = 0.01
@export_category("Echo")
@export var echo_room_size_multiplier: float = 2.0
@export var echo_interpolation: float = 0.01
@export_category("Ambient")
@export var ambient_direction_interpolation: float = 0.02
@export var ambient_volume_interpolation: float = 0.01
@export var ambient_volume_attenuation: float = 0.998

var room_size: float = 0.0
var ambience: float = 0.0
var ambient_dir: Vector3 = Vector3.ZERO


func _ready() -> void:
	if is_enabled:
		setup()

	# TODO: debugging tools
	# Performance.add_custom_monitor(&"raycast_audio/ambience", func(): return ambience)
	# Performance.add_custom_monitor(&"raycast_audio/echo_room_size", func(): return room_size)
	
	set_process(auto_update)


func setup() -> void:
	_setup_audio_buses()

	# Rays
	for __ in rays_count:
		var rc: AudioRay = AudioRay.new(max_raycast_dist, max_bounces)
		add_child(rc)


func _setup_audio_buses() -> void:
	# Reverb
	var i: int = AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(i, REVERB_BUS)
	AudioServer.set_bus_send(i, &"Master")
	var r: AudioEffectReverb = AudioEffectReverb.new()
	r.hipass = 1.0
	AudioServer.add_bus_effect(i, r)

	# Ambient
	i = AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(i, AMBIENT_BUS)
	AudioServer.set_bus_send(i, &"Master")
	AudioServer.add_bus_effect(i, AudioEffectPanner.new())


func clear():
	for ray: AudioRay in get_children():
		remove_child(ray)
		ray.queue_free()


func _process(delta: float) -> void:
	if !auto_update:
		set_process(false)
		return
	update()


func update():
	var echo: float = 0.0 # Avg echo from all tays
	var echo_count: int = 0 # Number of echo rays that came back
	var bounces_this_tick: int = 0
	var escaped_count: int = 0
	var escaped_dir: Vector3 = Vector3.ZERO # Avg escape direction
	var escaped_strength: float = 0.0

	# Gather data
	for ray: AudioRay in get_children():
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

	_update_muffle(bounces_this_tick)
	_update_echo(echo, echo_count, bounces_this_tick)
	_update_ambient(escaped_strength, escaped_dir)


func _update_muffle(bounces: int) -> void:
	for player: RaytracedAudioPlayer3D in get_tree().get_nodes_in_group(RaytracedAudioPlayer3D.GROUP_NAME):
		player.update(global_position, bounces, muffle_interpolation)


func _update_echo(echo: float, echo_count: int, bounces: int) -> void:
	# echo = echo / rays_count
	var reverb: AudioEffectReverb = AudioServer.get_bus_effect(AudioServer.get_bus_index(REVERB_BUS), 0)

	# Length -> echo delay
	room_size = lerpf(room_size, echo, echo_interpolation)
	var e: float = (room_size * echo_room_size_multiplier) / SPEED_OF_SOUND
	# print("e = ", e)
	reverb.room_size = lerpf(reverb.room_size, clampf(e, 0.0, 1.0), echo_interpolation)
	reverb.predelay_msec = lerpf(reverb.predelay_msec, e * 1000, echo_interpolation)
	reverb.predelay_feedback = lerpf(reverb.predelay_feedback, clampf(e, 0.0, 0.98), echo_interpolation)

	# More rays % -> echo strength
	var return_ratio: float = 0.0 if bounces == 0 else float(echo_count) / float(bounces)
	reverb.hipass = lerpf(reverb.hipass, 1.0 - return_ratio, echo_interpolation)
	# print("return_ratio = ", return_ratio)
	# print("hipass = ", reverb.hipass)


func _update_ambient(escaped_strength: float, escaped_dir: Vector3) -> void:
	var ambience_ratio: float = float(escaped_strength) / float(rays_count)
	var ambient_bus_idx: int = AudioServer.get_bus_index(AMBIENT_BUS)

	# More rays % -> louder
	if escaped_strength > 0:
		ambience = lerpf(ambience, 1.0, ambience_ratio)
	else:
		ambience *= ambient_volume_attenuation
	var volume: float = AudioServer.get_bus_volume_linear(ambient_bus_idx)
	AudioServer.set_bus_volume_linear(ambient_bus_idx, lerpf(volume, ambience, ambient_volume_interpolation))
	
	# Avg escape direction -> pan
	ambient_dir = ambient_dir.lerp(escaped_dir, ambient_direction_interpolation)
	var target_pan: float = 0.0 if ambient_dir.is_zero_approx() else owner.transform.basis.x.dot(ambient_dir.normalized())
	var pan: AudioEffectPanner = AudioServer.get_bus_effect(ambient_bus_idx, 0)
	pan.pan = target_pan


func _update_ray_configuration() -> void:
	for ray: AudioRay in get_children():
		ray.cast_dist = max_raycast_dist
		ray.max_bounces = max_bounces
