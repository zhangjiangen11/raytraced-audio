extends AudioStreamPlayer3D

## Currently, there is no way to muffle only one audio player (or apply any effect for that matter)
## So we create a new bus for every audio player that is audible from the RaytracedAudioListener
## Godot doesn't provide methods to calculate the volume of an audio at certain distances, so we calculate
## that ourselves (see calculate_audible_distance_threshold())

const RaytracedAudioListener: Script = preload("res://addons/raytraced_audio/raytraced_audio_listener.gd")

const GROUP_NAME: StringName = &"raytraced_audio_player_3d"
const ENABLED_GROUP_NAME: StringName = &"enabled_raytraced_audio_player_3d"
const CMP_EPSILON: float = 0.0001
const LOWPASS_MIN_HZ: float = 250.0
const LOWPASS_MAX_HZ: float = 20000.0

const LOG2: float = log(2.0)
const LOG_MIN_HZ: float = log(LOWPASS_MIN_HZ) / LOG2
const LOG_MAX_HZ: float = log(LOWPASS_MAX_HZ) / LOG2

@export var audibility_threshold_db: float = -30.0

var lowpass_rays_count: int = 0
var _is_enabled: bool = false


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)

func _ready() -> void:
	# Max distance not configured
	if max_distance == 0.0:
		max_distance = calculate_audible_distance_threshold()
		print("[", name, " (RaytracedAudioPlayer3D)] calculated max distance = ", max_distance)


func enable():
	if _is_enabled:
		return
	_is_enabled = true
	var i: int = _create_bus()
	bus = AudioServer.get_bus_name(i)
	add_to_group(ENABLED_GROUP_NAME)
	print("enabled!")

	# if DEBUG:
	# 	DebugLabel.new(self, str(name, " (RaytracedAudioPlayer3D)"))\
	# 		.with_name_replace("debuglabel")

func disable():
	if !_is_enabled:
		return
	assert(bus != RaytracedAudioListener.REVERB_BUS)
	
	var idx: int = AudioServer.get_bus_index(bus)
	if idx == -1:
		push_warning("audio bus ", bus, " not found")
		_disable()
		return
	_disable()
	AudioServer.remove_bus(idx)

func _disable():
	_is_enabled = false
	bus = RaytracedAudioListener.REVERB_BUS # Fallback
	remove_from_group(ENABLED_GROUP_NAME)
	lowpass_rays_count = 0

	# if DEBUG:
	# 	DebugLabel.remove_label(self, "debuglabel")


## Returns the index of the created bus
func _create_bus() -> int:
	var i: int = AudioServer.bus_count
	AudioServer.add_bus()
	AudioServer.set_bus_name(i, generate_bus_name())
	AudioServer.set_bus_send(i, RaytracedAudioListener.REVERB_BUS)
	AudioServer.add_bus_effect(i, AudioEffectLowPassFilter.new())
	return i

func generate_bus_name() -> String:
	return str("RTAudioPlayer3D_", name, randi())

func is_enabled() -> bool:
	return _is_enabled

func update(listener_pos: Vector3, total_bounces: int, interpolation: float) -> void:
	if _is_enabled:
		var idx: int = AudioServer.get_bus_index(bus)
		if idx == -1:
			push_warning("audio bus ", bus, " not found")
			_disable()
		else:
			var ratio: float = 0.0 if total_bounces == 0 else float(lowpass_rays_count) / float(total_bounces)
			var lowpass: AudioEffectLowPassFilter = AudioServer.get_bus_effect(idx, 0)

			# Frequencies aren't linear, they scale logarithmically (log2 space; +1 octave = 2x the frequency)
			# So we scale frequencies down before lerping, then scale them back up
			var log_t: float = lerpf(LOG_MIN_HZ, LOG_MAX_HZ, ratio)
			var log_hz: float = log(lowpass.cutoff_hz) / LOG2 # Scale current frequency down: ln(x) / ln(2) = log2(x)
			log_hz = lerpf(log_hz, log_t, interpolation) # Lerp in scaled down space
			lowpass.cutoff_hz = pow(2, log_hz) # Scale back up

	lowpass_rays_count = 0
	
	# Enable based on position
	var dist_sq: float = global_position.distance_squared_to(listener_pos)
	if dist_sq > max_distance*max_distance or !playing:
		disable()
	else:
		enable()


func get_volume_db_from_pos(from_pos: Vector3) -> float:
	var dist: float = from_pos.distance_to(global_position)
	var vol: float = 0.0
	match attenuation_model:
		ATTENUATION_INVERSE_DISTANCE:
			vol = linear_to_db(1.0 / ((dist / unit_size) + CMP_EPSILON))
		ATTENUATION_INVERSE_SQUARE_DISTANCE:
			var d: float = (dist / unit_size)
			vol = linear_to_db(1.0 / (d*d + CMP_EPSILON))
		ATTENUATION_LOGARITHMIC:
			vol = -20.0 * log(dist / unit_size + CMP_EPSILON)
		ATTENUATION_DISABLED:
			pass
		_:
			push_error("Unknown attenuation type: '", attenuation_model, "'")
	vol = minf(vol + volume_db, max_db)
	return vol


func is_audible(from_pos: Vector3) -> bool:
	return get_volume_db_from_pos(from_pos) >= audibility_threshold_db


func calculate_audible_distance_threshold() -> float:
	match attenuation_model:
		ATTENUATION_INVERSE_DISTANCE:
			var t_lin: float = db_to_linear(audibility_threshold_db - volume_db)
			# Unit_size / dist < T_lin
			return unit_size / t_lin
		ATTENUATION_INVERSE_SQUARE_DISTANCE:
			var t_lin: float = db_to_linear(audibility_threshold_db - volume_db)
			# (Unit_size / dist)^2 < T_lin
			return sqrt(unit_size*unit_size / t_lin)
		ATTENUATION_LOGARITHMIC:
			var t_db: float = audibility_threshold_db - volume_db
			# -20 * log(dist / Unit_size) > T_db
			return exp(t_db / -20.0) * unit_size
		ATTENUATION_DISABLED:
			return 0.0
		_:
			push_error("Unknown attenuation type: '", attenuation_model, "'")
			return 0.0
