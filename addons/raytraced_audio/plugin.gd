@tool
extends EditorPlugin


func _enter_tree() -> void:
	add_custom_type(
		"RaytracedAudioListener",
		"Node3D",
		load("res://addons/raytraced_audio/raytraced_audio_listener.gd"),
		null
	)

	add_custom_type(
		"RaytracedAudioPlayer3D",
		"AudioStreamPlayer3D",
		load("res://addons/raytraced_audio/raytraced_audio_player_3d.gd"),
		null
	)


func _exit_tree() -> void:
	remove_custom_type("RaytracedAudioListener")
	remove_custom_type("RaytracedAudioPlayer3D")
