extends Node

const SUCCESS_SCENE_PATH := "res://scenes/game_success.tscn"
const DEFAULT_MAZE_SCENE_PATH := "res://scenes/game.tscn"
const LARGER_MAZE_SCENE_PATH := "res://scenes/game2.tscn"

var current_level_index := 0
var levels := [
	{
		"level_number": 1,
		"display_name": "Level 1",
		"maze_scene_path": DEFAULT_MAZE_SCENE_PATH,
		"dweller_speed": 40.0,
		"detection_radius": 140.0,
		"search_duration": 5.0,
		"patrol_point_count": 5,
		"camps_enabled": false,
		"day_night_enabled": false,
		"aggressive_ai_enabled": false
	},
	{
		"level_number": 2,
		"display_name": "Level 2",
		"maze_scene_path": LARGER_MAZE_SCENE_PATH,
		"dweller_speed": 50,
		"detection_radius": 170.0,
		"search_duration": 7.0,
		"patrol_point_count": 7,
		"camps_enabled": true,
		"day_night_enabled": false,
		"aggressive_ai_enabled": false
	},
	{
		"level_number": 3,
		"display_name": "Level 3",
		"maze_scene_path": DEFAULT_MAZE_SCENE_PATH,
		"dweller_speed": 60,
		"detection_radius": 180.0,
		"search_duration": 8.0,
		"patrol_point_count": 8,
		"camps_enabled": true,
		"day_night_enabled": true,
		"aggressive_ai_enabled": false
	},
	{
		"level_number": 4,
		"display_name": "Level 4",
		"maze_scene_path": DEFAULT_MAZE_SCENE_PATH,
		"dweller_speed": 55.0,
		"detection_radius": 230.0,
		"search_duration": 9.0,
		"patrol_point_count": 10,
		"camps_enabled": true,
		"day_night_enabled": true,
		"aggressive_ai_enabled": false
	},
	{
		"level_number": 5,
		"display_name": "Level 5",
		"maze_scene_path": DEFAULT_MAZE_SCENE_PATH,
		"dweller_speed": 60.0,
		"detection_radius": 270.0,
		"search_duration": 12.0,
		"patrol_point_count": 12,
		"camps_enabled": true,
		"day_night_enabled": true,
		"aggressive_ai_enabled": true
	}
]


func get_active_level() -> Dictionary:
	return levels[current_level_index]


func reset_progression():
	current_level_index = 0


func advance_to_next_level() -> bool:
	if current_level_index >= levels.size() - 1:
		return false
	current_level_index += 1
	return true


func complete_current_level():
	get_tree().change_scene_to_file(SUCCESS_SCENE_PATH)


func proceed_from_success():
	if advance_to_next_level():
		get_tree().change_scene_to_file(get_active_level()["maze_scene_path"])
	else:
		reset_progression()
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn")
