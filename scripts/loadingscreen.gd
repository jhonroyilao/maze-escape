extends Control

@onready var progress_bar: TextureProgressBar = $TextureProgressBar

const GAME_SCENE_PATH = "res://scenes/game0.tscn"

var current_value: float = 0.0
var is_loading_started: bool = false

func _ready() -> void:
	progress_bar.value = 0.0
	if ResourceLoader.has_cached(GAME_SCENE_PATH):
		_change_to_game_scene(load(GAME_SCENE_PATH))
	else:
		var error = ResourceLoader.load_threaded_request(GAME_SCENE_PATH)
		if error == OK or error == ERR_BUSY:
			is_loading_started = true

func _process(delta: float) -> void:
	if not is_loading_started:
		return
		
	if current_value < 115.0:
		current_value += 20.0 * delta
		if current_value > 115.0:
			current_value = 115.0
			
	progress_bar.value = current_value

	if progress_bar.value >= 115.0:
		var progress = []
		var status = ResourceLoader.load_threaded_get_status(GAME_SCENE_PATH, progress)
		
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			set_process(false)
			var packed_scene = ResourceLoader.load_threaded_get(GAME_SCENE_PATH)
			_change_to_game_scene(packed_scene)
		elif status == ResourceLoader.THREAD_LOAD_FAILED:
			set_process(false)

func _change_to_game_scene(packed_scene: PackedScene) -> void:
	if packed_scene == null:
		get_tree().change_scene_to_file(GAME_SCENE_PATH)
		return
	get_tree().change_scene_to_packed(packed_scene)
