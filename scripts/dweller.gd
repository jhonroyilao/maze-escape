extends CharacterBody2D

enum State {
	PATROL,
	CHASE,
	SEARCH,
	CAMP_INVESTIGATION
}

var current_state: State = State.PATROL
var attack_radius := 24.0
var base_speed := 30.0
var speed := base_speed
var base_detection_radius := 180.0
var detection_radius := 180.0
var search_duration := 8.0
var waypoint_reached_distance := 4.0
var blocked_waypoint_skip_distance := 40.0
var unstuck_duration := 0.35
var unstuck_probe_distance := 18.0
var axis_probe_distance := 4.0
var patrol_candidate_limit := 300
var patrol_point_count := 8
var vertical_corridor_x_offset := -2.0
var corridor_center_tolerance := 0.5
var fire_breath_animation_names := ["breath", "fire", "run"]
var fire_breath_trigger_radius := 60.0
var is_fire_breathing := false
var roar_stream: AudioStream = preload("res://assets/Sounds/SFX/dragonroar.mp3")

@onready var anim := $AnimatedSprite2D
@onready var detection_area := $DetectionArea
@onready var collision_shape := $CollisionShape2D
@onready var debug_label := get_node_or_null("Label")
@onready var roar: AudioStreamPlayer = get_node_or_null("roar") as AudioStreamPlayer

var player: CharacterBody2D = null
var tilemap: TileMap = null
var astar := AStarGrid2D.new()
var cell_size := Vector2(16, 16)
var maze_rect := Rect2i(0, 0, 59, 42)
var path: Array[Vector2] = []
var path_index := 0
var player_in_sight := false
var last_known_player_pos := Vector2.ZERO
var search_timer := 0.0
var patrol_points: Array[Vector2] = []
var patrol_index := 0
var repath_timer := 0.0
var wander_timer := 0.0
var wander_interval := 3.0
var current_target := Vector2.ZERO
var camp: Area2D = null
var player_in_camp := false

var debug_timer := 0.0
var stuck_timer := 0.0
var last_position := Vector2.ZERO
var stuck_threshold := 4.0
var blocked_waypoint_frames := 0
var is_unstucking := false
var unstuck_timer := 0.0
var unstuck_direction := Vector2.ZERO
var unstuck_target := Vector2.ZERO

# ++ Game over flag to prevent double-triggering
var caught := false


# =========================================================
# READY
# =========================================================
func _ready():
	add_to_group("dwellers")
	tilemap = get_parent().get_node("TileMap")
	player = get_parent().get_node("Player")
	if roar:
		roar.stream = roar_stream

	_build_astar()
	_apply_active_level_settings()
	_generate_patrol_points(patrol_point_count)

	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)
	anim.animation_changed.connect(_on_animation_changed)
	anim.animation_looped.connect(_on_animation_looped)

	camp = get_parent().get_node_or_null("Camp")
	if camp:
		camp.body_entered.connect(_on_camp_body_entered)
		camp.body_exited.connect(_on_camp_body_exited)
		_block_camp_in_astar()
		print("[DWELLER] Camp zone loaded")
	else:
		print("[DWELLER] No camp found")
		
	_play_idle_animation()
	last_position = global_position

	print("[DWELLER] AI INITIALIZED")
	print("[DWELLER] Position: ", global_position)

	await get_tree().process_frame
	_start_patrol()
	


# =========================================================
# MAIN LOOP
# =========================================================
func _physics_process(delta):
	if caught or not is_inside_tree():
		return

	velocity = Vector2.ZERO

	_check_player_visibility()
	_check_catch_player()        # ++ game over check
	if is_unstucking:
		_move_unstuck(delta)
	else:
		_run_behavior(delta)
		_move_along_path(delta)
	_update_animation()
	_debug_tick(delta)


# =========================================================
# CATCH PLAYER -> GAME OVER                              ++
# =========================================================
func _check_catch_player():
	if player == null or caught:
		return

	var dist = global_position.distance_to(player.global_position)
	if dist <= attack_radius:
		caught = true
		print("[DWELLER] PLAYER CAUGHT -> GAME OVER")
		get_tree().call_deferred("change_scene_to_file", "res://scenes/game_over.tscn")


# =========================================================
# LEVEL SETTINGS
# =========================================================
func configure_for_level(level_data: Dictionary):
	base_speed = float(level_data.get("dweller_speed", base_speed))
	base_detection_radius = float(level_data.get("detection_radius", base_detection_radius))
	speed = base_speed
	detection_radius = base_detection_radius
	search_duration = float(level_data.get("search_duration", search_duration))
	patrol_point_count = int(level_data.get("patrol_point_count", patrol_point_count))


func set_night_intensity(intensity: float) -> void:
	var clamped_intensity := clampf(intensity, 0.0, 1.0)
	speed = lerpf(base_speed, base_speed * 1.10, clamped_intensity)
	detection_radius = lerpf(base_detection_radius, base_detection_radius * 1.25, clamped_intensity)


func _apply_active_level_settings():
	var level_manager = get_node_or_null("/root/LevelManager")
	if level_manager == null:
		return
	configure_for_level(level_manager.get_active_level())


# =========================================================
# FSM
# =========================================================
func _set_state(next_state: State):
	if current_state == next_state:
		return

	var was_chasing = current_state == State.CHASE
	current_state = next_state
	var is_chasing = current_state == State.CHASE

	if not was_chasing and is_chasing:
		_start_chase_music()
	elif was_chasing and not is_chasing:
		_stop_chase_music()


func _run_behavior(delta):
	match current_state:
		State.CHASE:
			repath_timer += delta
			if repath_timer >= 0.4:
				repath_timer = 0.0
				if player_in_sight and player:
					_set_path_to(player.global_position)

		State.SEARCH:
			search_timer -= delta
			if search_timer <= 0:
				print("[DWELLER] Search expired -> PATROL")
				_set_state(State.PATROL)
				path.clear()
				path_index = 0
				_advance_patrol()
				return
			if _path_exhausted():
				var offset = Vector2(
					randf_range(-64, 64),
					randf_range(-64, 64)
				)
				_set_path_to(last_known_player_pos + offset)

		State.CAMP_INVESTIGATION:
			pass

		State.PATROL:
			wander_timer += delta
			if _path_exhausted():
				wander_timer = 0.0
				_advance_patrol()
			elif wander_timer >= wander_interval:
				wander_timer = 0.0
				print("[DWELLER] Wander timeout -> repath")
				path.clear()
				path_index = 0
				_advance_patrol()


# =========================================================
# PATH CHECK
# =========================================================
func _path_exhausted() -> bool:
	return path.is_empty() or path_index >= path.size()


# =========================================================
# ADVANCE PATROL
# =========================================================
func _advance_patrol():
	if patrol_points.is_empty():
		return
	for i in range(patrol_points.size()):
		patrol_index = (patrol_index + 1) % patrol_points.size()
		var target = patrol_points[patrol_index]
		_set_path_to(target)
		if not _path_exhausted():
			print("[DWELLER] Patrol -> ", patrol_index)
			return
	print("[DWELLER] All patrol points failed")
	_generate_patrol_points(8)
	if not patrol_points.is_empty():
		_set_path_to(patrol_points[0])


# =========================================================
# PLAYER DETECTION
# =========================================================
func _check_player_visibility():
	if player == null:
		return

		# ++ Camp protection
	if player_in_camp:
		if player_in_sight:
			player_in_sight = false
		return

	var dist = global_position.distance_to(player.global_position)

	if dist <= detection_radius:
		if not player_in_sight:
			player_in_sight = true
			print("[DWELLER] PLAYER SPOTTED")
			path.clear()
			path_index = 0
			_set_state(State.CHASE)
	else:
		if player_in_sight:
			player_in_sight = false
			print("[DWELLER] PLAYER LOST")
			if current_state == State.CHASE:
				last_known_player_pos = player.global_position
				search_timer = search_duration
				_set_state(State.SEARCH)
				path.clear()
				path_index = 0


# =========================================================
# SIGNALS
# =========================================================
func _on_body_entered(body):
	if body.name == "Player":
		if player_in_camp:
			return
		print("[DWELLER] Player entered detection")
		player_in_sight = true
		path.clear()
		path_index = 0
		_set_state(State.CHASE)


func _on_body_exited(body):
	if body.name == "Player":
		print("[DWELLER] Player exited detection")
		player_in_sight = false
		if current_state == State.CHASE:
			last_known_player_pos = player.global_position
			search_timer = search_duration
			_set_state(State.SEARCH)
			path.clear()
			path_index = 0


# =========================================================
# BUILD A STAR 
# =========================================================
func _build_astar():
	maze_rect = tilemap.get_used_rect()
	astar.region = maze_rect
	astar.cell_size = cell_size
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.update()

	var solid_count := 0
	var inflated_count := 0
	var solid_cells: Array[Vector2i] = []
	for x in range(maze_rect.position.x, maze_rect.end.x):
		for y in range(maze_rect.position.y, maze_rect.end.y):
			var cell = Vector2i(x, y)
			var tile_data = tilemap.get_cell_tile_data(0, cell)
			if tile_data:
				if tile_data.get_collision_polygons_count(0) > 0:
					astar.set_point_solid(cell, true)
					solid_cells.append(cell)
					solid_count += 1

	var clearance_offsets = _get_clearance_offsets()
	for solid_cell in solid_cells:
		for offset in clearance_offsets:
			var padded_cell = solid_cell + offset
			if astar.is_in_boundsv(padded_cell) and not astar.is_point_solid(padded_cell):
				astar.set_point_solid(padded_cell, true)
				inflated_count += 1

	print("[DWELLER] ASTAR READY | solids: ", solid_count, " | clearance: ", inflated_count)


func _get_clearance_offsets() -> Array[Vector2i]:
	var offsets: Array[Vector2i] = []
	if collision_shape == null or not collision_shape.shape is RectangleShape2D:
		return offsets

	var rect_shape := collision_shape.shape as RectangleShape2D
	var shape_scale = global_scale.abs()
	var shape_center = collision_shape.position * shape_scale
	var shape_extents = rect_shape.size * shape_scale * 0.5
	var tile_extents = cell_size * 0.5
	var max_offset_x = int(ceil((shape_extents.x + tile_extents.x + abs(shape_center.x)) / cell_size.x))
	var max_offset_y = int(ceil((shape_extents.y + tile_extents.y + abs(shape_center.y)) / cell_size.y))

	for dx in range(-max_offset_x, max_offset_x + 1):
		for dy in range(-max_offset_y, max_offset_y + 1):
			var offset = Vector2i(dx, dy)
			if offset == Vector2i.ZERO:
				continue
			if _body_at_offset_overlaps_wall(offset, shape_center, shape_extents, tile_extents):
				offsets.append(offset)

	return offsets


func _body_at_offset_overlaps_wall(offset: Vector2i, shape_center: Vector2, shape_extents: Vector2, tile_extents: Vector2) -> bool:
	var body_center = Vector2(offset) * cell_size + shape_center
	var body_min = body_center - shape_extents
	var body_max = body_center + shape_extents
	var wall_min = -tile_extents
	var wall_max = tile_extents

	return body_min.x < wall_max.x and body_max.x > wall_min.x and body_min.y < wall_max.y and body_max.y > wall_min.y



# =========================================================
# ACTUAL A STAR ALGORITHM FUNCTION
# =========================================================

func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _get_neighbors(cell: Vector2i) -> Array[Vector2i]:
	var neighbors: Array[Vector2i] = []
	var directions = [
		Vector2i.RIGHT,
		Vector2i.LEFT,
		Vector2i.UP,
		Vector2i.DOWN
	]

	for dir in directions:
		var next = cell + dir

		if not astar.is_in_boundsv(next):
			continue

		if astar.is_point_solid(next):
			continue

		neighbors.append(next)

	return neighbors


func _lowest_f_score(open_set: Array[Vector2i], f_score: Dictionary) -> Vector2i:
	var best = open_set[0]
	var best_score = f_score.get(best, INF)

	for node in open_set:
		var score = f_score.get(node, INF)

		if score < best_score:
			best_score = score
			best = node

	return best


func _reconstruct_path(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = [current]

	while came_from.has(current):
		current = came_from[current]
		result.push_front(current)

	return result


func _manual_astar(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:

	var open_set: Array[Vector2i] = [start]

	var came_from := {}

	var g_score := {}
	var f_score := {}

	g_score[start] = 0.0
	f_score[start] = _heuristic(start, goal)

	while not open_set.is_empty():

		var current = _lowest_f_score(open_set, f_score)

		if current == goal:
			return _reconstruct_path(came_from, current)

		open_set.erase(current)

		for neighbor in _get_neighbors(current):

			var tentative_g = g_score.get(current, INF) + 1.0

			if tentative_g < g_score.get(neighbor, INF):

				came_from[neighbor] = current
				g_score[neighbor] = tentative_g
				f_score[neighbor] = tentative_g + _heuristic(neighbor, goal)

				if not open_set.has(neighbor):
					open_set.append(neighbor)

	return []
	
	
#====================
# BLOCK CAMP SA A*
# ==================
# ++ Block camp area sa A* para hindi makapasok ang dweller
func _block_camp_in_astar():
	if camp == null:
		return
	var shape_node = camp.get_node_or_null("CollisionShape2D")
	if shape_node == null or not shape_node.shape is RectangleShape2D:
		return

	var rect_shape := shape_node.shape as RectangleShape2D
	var center = tilemap.local_to_map(tilemap.to_local(camp.global_position))
	var half = rect_shape.size / 2.0
	# convert pixel half-extents to tile counts, +1 buffer
	var tx = int(ceil(half.x / cell_size.x)) + 1
	var ty = int(ceil(half.y / cell_size.y)) + 1

	for dx in range(-tx, tx + 1):
		for dy in range(-ty, ty + 1):
			var cell = center + Vector2i(dx, dy)
			if astar.is_in_boundsv(cell):
				astar.set_point_solid(cell, true)

	print("[DWELLER] Camp blocked in astar")


func _on_camp_body_entered(body):
	if body.name == "Player":
		player_in_camp = true
		print("[DWELLER] Player entered camp -> safe")
		# ++ If currently chasing, drop it
		if current_state == State.CHASE or current_state == State.SEARCH:
			player_in_sight = false
			_set_state(State.PATROL)
			path.clear()
			path_index = 0
			_advance_patrol()


func _on_camp_body_exited(body):
	if body.name == "Player":
		player_in_camp = false
		print("[DWELLER] Player left camp")

# =========================================================
# PATHFINDING
# =========================================================
func _set_path_to(world_target: Vector2):
	var from_cell = tilemap.local_to_map(tilemap.to_local(global_position))
	var to_cell = tilemap.local_to_map(tilemap.to_local(world_target))

	from_cell = from_cell.clamp(
		maze_rect.position,
		maze_rect.position + maze_rect.size - Vector2i.ONE
	)
	to_cell = to_cell.clamp(
		maze_rect.position,
		maze_rect.position + maze_rect.size - Vector2i.ONE
	)

	if astar.is_point_solid(from_cell):
		from_cell = _find_nearest_walkable(from_cell)

	var path_target_cell = to_cell
	var id_path: Array[Vector2i] = []
	if not astar.is_point_solid(to_cell):
		id_path = _manual_astar(from_cell, path_target_cell)
	if id_path.size() < 2:
		var reachable = _find_reachable_path_near_target(from_cell, to_cell)
		if not reachable.is_empty():
			path_target_cell = reachable[0]
			id_path = reachable[1]

	if id_path.size() < 2:
		print("[DWELLER] NO PATH")
		path.clear()
		path_index = 0
		return

	path.clear()
	path_index = 0
	current_target = tilemap.to_global(tilemap.map_to_local(path_target_cell))
	for cell in id_path:
		path.append(tilemap.to_global(tilemap.map_to_local(cell)))
	_skip_reached_waypoints()

	print("[DWELLER] Path created: ", path.size(), " nodes")


# =========================================================
# WALKABLE CELL
# =========================================================
func _find_nearest_walkable(cell: Vector2i) -> Vector2i:
	for radius in range(1, 9):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var check = cell + Vector2i(dx, dy)
				if astar.is_in_boundsv(check):
					if not astar.is_point_solid(check):
						return check
	return cell


func _find_reachable_path_near_target(from_cell: Vector2i, target_cell: Vector2i) -> Array:
	var candidates: Array[Vector2i] = []
	for radius in range(0, 9):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				if radius > 0 and abs(dx) != radius and abs(dy) != radius:
					continue
				var check = target_cell + Vector2i(dx, dy)
				if check != from_cell and astar.is_in_boundsv(check) and not astar.is_point_solid(check):
					candidates.append(check)

	candidates.sort_custom(func(a, b):
		var a_target_dist = Vector2(a).distance_squared_to(Vector2(target_cell))
		var b_target_dist = Vector2(b).distance_squared_to(Vector2(target_cell))
		if a_target_dist == b_target_dist:
			return Vector2(a).distance_squared_to(Vector2(from_cell)) < Vector2(b).distance_squared_to(Vector2(from_cell))
		return a_target_dist < b_target_dist
	)

	for candidate in candidates:
		var candidate_path: Array[Vector2i] = []
		candidate_path = _manual_astar(from_cell, candidate)
		if candidate_path.size() >= 2:
			print("[DWELLER] Target blocked -> nearest reachable: ", candidate)
			return [candidate, candidate_path]

	return []


# =========================================================
# MOVEMENT
# =========================================================
func _move_along_path(delta):
	if not is_inside_tree():
		return
	if _path_exhausted():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	_skip_reached_waypoints()

	if _path_exhausted():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var target = current_target if path_index >= path.size() else path[path_index]
	var dir = target - global_position

	if dir.length() < 2.0:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var move_direction = _get_grid_move_direction(target)
	var alternate_direction = _get_alternate_grid_direction(target, move_direction)
	if _is_axis_step_blocked(move_direction, delta) and alternate_direction != Vector2.ZERO:
		if not _is_axis_step_blocked(alternate_direction, delta):
			move_direction = alternate_direction

	if move_direction == Vector2.ZERO:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var desired_velocity = move_direction * speed
	velocity = desired_velocity
	move_and_slide()

	if _is_blocked_toward_waypoint(desired_velocity, target):
		blocked_waypoint_frames += 1
		if blocked_waypoint_frames >= 6:
			_start_unstuck(target)
			blocked_waypoint_frames = 0
	else:
		blocked_waypoint_frames = 0


func _get_grid_move_direction(target: Vector2) -> Vector2:
	var current_cell = tilemap.local_to_map(tilemap.to_local(global_position))
	var target_cell = tilemap.local_to_map(tilemap.to_local(target))
	var delta = target - global_position
	var current_cell_center = tilemap.to_global(tilemap.map_to_local(current_cell))

	if target_cell.x != current_cell.x and target_cell.y == current_cell.y:
		return Vector2(sign(delta.x), 0)
	if target_cell.y != current_cell.y and target_cell.x == current_cell.x:
		var vertical_lane_x = current_cell_center.x + vertical_corridor_x_offset
		var lane_delta_x = vertical_lane_x - global_position.x
		if abs(lane_delta_x) > corridor_center_tolerance:
			return Vector2(sign(lane_delta_x), 0)
		return Vector2(0, sign(delta.y))

	if abs(delta.x) >= abs(delta.y):
		return Vector2(sign(delta.x), 0) if abs(delta.x) > 1.0 else Vector2.ZERO
	return Vector2(0, sign(delta.y)) if abs(delta.y) > 1.0 else Vector2.ZERO


func _get_alternate_grid_direction(target: Vector2, primary_direction: Vector2) -> Vector2:
	var delta = target - global_position
	if primary_direction.x != 0 and abs(delta.y) > 1.0:
		return Vector2(0, sign(delta.y))
	if primary_direction.y != 0 and abs(delta.x) > 1.0:
		return Vector2(sign(delta.x), 0)
	return Vector2.ZERO


func _is_axis_step_blocked(direction: Vector2, delta: float) -> bool:
	if direction == Vector2.ZERO:
		return true
	if not is_inside_tree():
		return false
	var probe_distance = max(axis_probe_distance, speed * delta)
	return test_move(global_transform, direction * probe_distance)


func _move_unstuck(delta):
	unstuck_timer -= delta
	velocity = unstuck_direction * speed
	move_and_slide()

	if unstuck_timer <= 0.0 or _is_unstuck_blocked():
		_finish_unstuck()


func _start_unstuck(target: Vector2):
	if is_unstucking:
		return

	unstuck_target = target
	unstuck_direction = _choose_unstuck_direction(target)
	if unstuck_direction == Vector2.ZERO:
		print("[DWELLER] STUCK -> REPATH")
		_repath_current_goal()
		return

	print("[DWELLER] STUCK -> UNSTUCK")
	print("[DWELLER] UNSTUCK DIR: ", unstuck_direction)
	is_unstucking = true
	unstuck_timer = unstuck_duration
	path.clear()
	path_index = 0


func _finish_unstuck():
	if not is_unstucking:
		return

	print("[DWELLER] UNSTUCK DONE -> REPATH")
	is_unstucking = false
	unstuck_timer = 0.0
	unstuck_direction = Vector2.ZERO
	blocked_waypoint_frames = 0
	last_position = global_position
	stuck_timer = 0.0
	_repath_current_goal()


func _choose_unstuck_direction(target: Vector2) -> Vector2:
	var wall_normal = _get_average_collision_normal()
	if wall_normal == Vector2.ZERO:
		wall_normal = (global_position - target).normalized()

	var goal_dir = (target - global_position).normalized()
	var directions = [
		Vector2.RIGHT,
		Vector2.LEFT,
		Vector2.DOWN,
		Vector2.UP
	]

	var best_dir := Vector2.ZERO
	var best_score := -INF
	for direction in directions:
		if not _is_unstuck_direction_open(direction):
			continue

		var score = direction.dot(goal_dir) * 3.0
		score += direction.dot(wall_normal) * 0.75
		if score > best_score:
			best_score = score
			best_dir = direction

	return best_dir


func _is_unstuck_direction_open(direction: Vector2) -> bool:
	if test_move(global_transform, direction * unstuck_probe_distance):
		return false

	var probe_cell = tilemap.local_to_map(tilemap.to_local(global_position + direction * cell_size.x))
	if not astar.is_in_boundsv(probe_cell):
		return false
	if astar.is_point_solid(probe_cell):
		return false

	return true


func _is_unstuck_blocked() -> bool:
	if get_slide_collision_count() == 0:
		return false

	for i in range(get_slide_collision_count()):
		var collision = get_slide_collision(i)
		if collision.get_normal().dot(unstuck_direction) < -0.35:
			return true
	return false


func _get_average_collision_normal() -> Vector2:
	var normal := Vector2.ZERO
	for i in range(get_slide_collision_count()):
		normal += get_slide_collision(i).get_normal()
	return normal.normalized() if normal != Vector2.ZERO else Vector2.ZERO


func _repath_current_goal():
	match current_state:
		State.CHASE:
			if player:
				_set_path_to(player.global_position)
		State.SEARCH:
			_set_path_to(last_known_player_pos)
		State.PATROL:
			if not patrol_points.is_empty():
				_set_path_to(patrol_points[patrol_index])
			else:
				_advance_patrol()


func _skip_reached_waypoints():
	while path_index < path.size():
		var target_cell = tilemap.local_to_map(tilemap.to_local(path[path_index]))
		var current_cell = tilemap.local_to_map(tilemap.to_local(global_position))
		var is_intermediate_same_cell = target_cell == current_cell and path_index < path.size() - 1
		if is_intermediate_same_cell or global_position.distance_to(path[path_index]) <= waypoint_reached_distance:
			path_index += 1
		else:
			break


func _is_blocked_toward_waypoint(desired_velocity: Vector2, target: Vector2) -> bool:
	if get_slide_collision_count() == 0:
		return false
	if global_position.distance_to(target) > blocked_waypoint_skip_distance:
		return false

	var desired_dir = desired_velocity.normalized()
	for i in range(get_slide_collision_count()):
		var collision = get_slide_collision(i)
		if collision.get_normal().dot(desired_dir) < -0.35:
			return true
	return false


# =========================================================
# PATROL POINTS
# =========================================================
func _generate_patrol_points(count: int):
	patrol_points.clear()
	var walkable: Array[Vector2i] = []
	for x in range(maze_rect.position.x, maze_rect.end.x):
		for y in range(maze_rect.position.y, maze_rect.end.y):
			var cell = Vector2i(x, y)
			if astar.is_in_boundsv(cell):
				if not astar.is_point_solid(cell):
					walkable.append(cell)

	walkable.shuffle()

	var origin = tilemap.local_to_map(tilemap.to_local(global_position))
	if astar.is_point_solid(origin):
		origin = _find_nearest_walkable(origin)

	var checked := 0
	for cell in walkable:
		if patrol_points.size() >= count:
			break
		checked += 1
		var test = _manual_astar(origin, cell)
		if test.size() > 0:
			patrol_points.append(tilemap.to_global(tilemap.map_to_local(cell)))
		if checked >= patrol_candidate_limit:
			break

	print("[DWELLER] Patrol points: ", patrol_points.size())


# =========================================================
# START PATROL
# =========================================================
func _start_patrol():
	if patrol_points.is_empty():
		print("[DWELLER] NO PATROL POINTS")
		return
	patrol_index = 0
	print("[DWELLER] START PATROL")
	_set_path_to(patrol_points[0])


# =========================================================
# MUSIC
# =========================================================
func _start_chase_music():
	var game_bg_music = get_node_or_null("/root/GameBgMusic") as AudioStreamPlayer
	if game_bg_music:
		game_bg_music.stop()
	var chase_bg_music = get_node_or_null("/root/ChaseBgMusic") as AudioStreamPlayer
	if chase_bg_music and not chase_bg_music.playing:
		chase_bg_music.play()


func _stop_chase_music():
	var chase_bg_music = get_node_or_null("/root/ChaseBgMusic") as AudioStreamPlayer
	if chase_bg_music:
		chase_bg_music.stop()
	var game_bg_music = get_node_or_null("/root/GameBgMusic") as AudioStreamPlayer
	if game_bg_music and not game_bg_music.playing:
		game_bg_music.play()


# =========================================================
# DEBUG
# =========================================================
func _debug_tick(delta):
	debug_timer += delta
	stuck_timer += delta

	if debug_timer >= 2.0:
		debug_timer = 0.0
		var state_name = State.keys()[current_state]
		print("--------------------------------")
		print("[DWELLER] STATE: ", state_name)
		print("[DWELLER] POS: ", global_position)
		print("[DWELLER] PATH: ", path_index, "/", path.size())
		if not _path_exhausted():
			print("[DWELLER] TARGET: ", path[path_index], " | DIST: ", global_position.distance_to(path[path_index]))
		if debug_label:
			debug_label.text = "[%s]\n%d/%d" % [state_name, path_index, path.size()]

	if stuck_timer >= stuck_threshold:
		stuck_timer = 0.0
		var moved = global_position.distance_to(last_position)
		if moved < 5.0 and not is_unstucking:
			var target = current_target
			if not _path_exhausted():
				target = path[path_index]
			_start_unstuck(target)
		last_position = global_position


# =========================================================
# ANIMATION
# =========================================================
func _update_animation():
	if not _should_play_fire_breath_animation():
		_play_idle_animation()
		return

	if is_fire_breathing:
		return

	_start_fire_breath_animation()


func _play_animation(animation_name: StringName):
	if anim.animation == animation_name and anim.is_playing():
		return
	anim.play(animation_name)


func _on_animation_changed():
	pass


func _on_animation_looped():
	if _is_fire_breath_animation(anim.animation):
		_play_roar()


func _is_fire_breath_animation(animation_name: StringName) -> bool:
	var normalized_name = String(animation_name).to_lower()
	for fire_breath_name in fire_breath_animation_names:
		if normalized_name.contains(fire_breath_name):
			return true
	return false


func _play_roar():
	if roar == null:
		return
	roar.play()


func _should_play_fire_breath_animation() -> bool:
	if player == null:
		return false
	return global_position.distance_to(player.global_position) <= fire_breath_trigger_radius


func _start_fire_breath_animation():
	is_fire_breathing = true
	_play_animation("run")
	_play_roar()


func _play_idle_animation():
	is_fire_breathing = false
	_play_animation("idle")
