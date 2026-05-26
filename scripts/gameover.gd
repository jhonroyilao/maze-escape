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
		match event.keycode:
			KEY_ENTER, KEY_KP_ENTER:
				get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
			KEY_ESCAPE:
				get_tree().quit()
