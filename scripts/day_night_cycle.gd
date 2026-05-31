extends CanvasModulate

const DAY_DURATION := 12.0
const NIGHT_TRANSITION_DURATION := 3.0
const NIGHT_DURATION := 12.0
const DAY_TRANSITION_DURATION := 3.0
const NIGHT_COLOR := Color(0.45, 0.56, 0.82, 1.0)

enum Phase {
	DAY,
	TO_NIGHT,
	NIGHT,
	TO_DAY
}

var phase := Phase.DAY
var phase_timer := 0.0
var night_intensity := 0.0


func _ready() -> void:
	color = Color.WHITE

	var level_manager = get_node_or_null("/root/LevelManager")
	if level_manager == null:
		set_process(false)
		return

	var level_data: Dictionary = level_manager.get_active_level()
	if not bool(level_data.get("day_night_enabled", false)):
		_apply_night_intensity(0.0)
		set_process(false)
		return

	_apply_night_intensity(0.0)


func _process(delta: float) -> void:
	phase_timer += delta

	match phase:
		Phase.DAY:
			night_intensity = 0.0
			if phase_timer >= DAY_DURATION:
				_start_phase(Phase.TO_NIGHT)
		Phase.TO_NIGHT:
			night_intensity = clampf(phase_timer / NIGHT_TRANSITION_DURATION, 0.0, 1.0)
			if phase_timer >= NIGHT_TRANSITION_DURATION:
				_start_phase(Phase.NIGHT)
		Phase.NIGHT:
			night_intensity = 1.0
			if phase_timer >= NIGHT_DURATION:
				_start_phase(Phase.TO_DAY)
		Phase.TO_DAY:
			night_intensity = 1.0 - clampf(phase_timer / DAY_TRANSITION_DURATION, 0.0, 1.0)
			if phase_timer >= DAY_TRANSITION_DURATION:
				_start_phase(Phase.DAY)

	_apply_night_intensity(night_intensity)


func _start_phase(next_phase: Phase) -> void:
	phase = next_phase
	phase_timer = 0.0


func _apply_night_intensity(intensity: float) -> void:
	night_intensity = clampf(intensity, 0.0, 1.0)
	color = Color.WHITE.lerp(NIGHT_COLOR, night_intensity)
	get_tree().call_group("dwellers", "set_night_intensity", night_intensity)
