extends CanvasModulate

const DAY_DURATION := 12.0
const NIGHT_TRANSITION_DURATION := 3.0
const NIGHT_DURATION := 12.0
const DAY_TRANSITION_DURATION := 3.0
const NIGHT_COLOR := Color(0.45, 0.56, 0.82, 1.0)
const WARNING_DURATION := 1.5

enum Phase {
	DAY,
	TO_NIGHT,
	NIGHT,
	TO_DAY
}

var phase := Phase.DAY
var phase_timer := 0.0
var night_intensity := 0.0
var warning_timer := 0.0
var timer_label: Label = null
var warning_label: Label = null


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

	_create_timer_ui()
	_apply_night_intensity(0.0)
	_update_timer_ui()


func _process(delta: float) -> void:
	phase_timer += delta
	warning_timer = maxf(warning_timer - delta, 0.0)

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
	_update_timer_ui()


func _start_phase(next_phase: Phase) -> void:
	phase = next_phase
	phase_timer = 0.0
	if phase == Phase.TO_NIGHT or phase == Phase.TO_DAY:
		warning_timer = WARNING_DURATION


func _apply_night_intensity(intensity: float) -> void:
	night_intensity = clampf(intensity, 0.0, 1.0)
	color = Color.WHITE.lerp(NIGHT_COLOR, night_intensity)
	get_tree().call_group("dwellers", "set_night_intensity", night_intensity)


func _create_timer_ui() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DayNightTimerLayer"
	layer.layer = 20
	add_child(layer)

	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(250, 78)
	panel.offset_left = 12.0
	panel.offset_top = 12.0
	root.add_child(panel)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.72)
	style.border_color = Color(0.75, 0.82, 1.0, 0.42)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 14.0
	style.content_margin_top = 10.0
	style.content_margin_right = 14.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	panel.add_child(stack)

	timer_label = Label.new()
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	timer_label.add_theme_font_size_override("font_size", 20)
	timer_label.add_theme_color_override("font_color", Color(0.92, 0.95, 1.0, 1.0))
	stack.add_child(timer_label)

	warning_label = Label.new()
	warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	warning_label.add_theme_font_size_override("font_size", 15)
	warning_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.36, 1.0))
	stack.add_child(warning_label)


func _update_timer_ui() -> void:
	if timer_label == null or warning_label == null:
		return

	timer_label.text = _get_timer_text()

	var is_transition := phase == Phase.TO_NIGHT or phase == Phase.TO_DAY
	if is_transition:
		warning_label.text = _get_transition_warning_text()
		warning_label.visible = true
	elif warning_timer > 0.0:
		warning_label.text = "Transition started"
		warning_label.visible = true
	else:
		warning_label.visible = false


func _get_timer_text() -> String:
	match phase:
		Phase.DAY:
			return "Night in %ss" % [_seconds_remaining_text(DAY_DURATION)]
		Phase.TO_NIGHT:
			return "Nightfall %ss" % [_seconds_remaining_text(NIGHT_TRANSITION_DURATION)]
		Phase.NIGHT:
			return "Day in %ss" % [_seconds_remaining_text(NIGHT_DURATION)]
		Phase.TO_DAY:
			return "Dawn %ss" % [_seconds_remaining_text(DAY_TRANSITION_DURATION)]
	return ""


func _get_transition_warning_text() -> String:
	if phase == Phase.TO_NIGHT:
		return "Warning: night is falling"
	if phase == Phase.TO_DAY:
		return "Warning: dawn transition"
	return ""


func _seconds_remaining_text(duration: float) -> String:
	var seconds_remaining := maxf(duration - phase_timer, 0.0)
	return str(int(ceil(seconds_remaining)))
