extends Control

func _ready():
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


# =========================================================
# INPUT
# =========================================================
func _input(event):
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER:
			get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()

func _on_next_level_pressed():
	get_tree().change_scene_to_file("res://scenes/game.tscn")
