extends Control

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


# =========================================================
# INPUT
# =========================================================
func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			_confirm_next_step()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()


func _on_next_level_pressed():
	_confirm_next_step()


func _confirm_next_step():
	var level_manager = get_node_or_null("/root/LevelManager")
	if level_manager:
		level_manager.proceed_from_success()
	else:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
