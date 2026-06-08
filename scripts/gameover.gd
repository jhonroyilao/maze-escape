extends Control

# =========================================================
# READY
# =========================================================
func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


# =========================================================
# INPUT
# =========================================================
func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			_reset_level_progression()
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()


# =========================================================
# LEVEL PROGRESSION
# =========================================================
func _reset_level_progression():
	var level_manager = get_node_or_null("/root/LevelManager")
	if level_manager and level_manager.has_method("reset_progression"):
		level_manager.reset_progression()


# =========================================================
# PLAY AGAIN BUTTON
# =========================================================
func _on_play_again_pressed():
	var level_manager = get_node_or_null("/root/LevelManager")
	if level_manager and level_manager.has_method("restart_from_game_over"):
		level_manager.restart_from_game_over()
	else:
		get_tree().change_scene_to_file("res://scenes/game0.tscn")
