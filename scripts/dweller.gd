extends CharacterBody2D

enum State {
	PATROL,
	CHASE,
	SEARCH,
	CAMP_INVESTIGATION
}

var current_state: State = State.PATROL
var attack_radius := 24.0
var base_speed := 10.0
var speed := base_speed
var detection_radius := 180.0
var search_duration := 8.0
var waypoint_reached_distance := 4.0
var blocked_waypoint_skip_distance := 40.0
var unstuck_duration := 0.35
var unstuck_probe_distance := 18.0
var axis_probe_distance := 4.0
var patrol_candidate_limit := 300
var vertical_corridor_x_offset := -2.0
var corridor_center_tolerance := 0.5

@onready var anim := $AnimatedSprite2D
@onready var detection_area := $DetectionArea
@onready var collision_shape := $CollisionShape2D
@onready var debug_label := get_node_or_null("Label")

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
	tilemap = get_parent().get_node("TileMap")
	player = get_parent().get_node("Player")

	_build_astar()
	_generate_patrol_points(8)

	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)

	anim.play("run")
	last_position = global_position

	print("[DWELLER] AI INITIALIZED")
	print("[DWELLER] Position: ", global_position)

	await get_tree().process_frame
	_start_patrol()


# =========================================================
# MAIN LOOP
# =========================================================
func _physics_process(delta):
	if caught:
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
		get_tree().change_scene_to_file("res://scenes/game_over.tscn")


# =========================================================
# FSM
# =========================================================
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
				current_state = State.PATROL
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

	var dist = global_position.distance_to(player.global_position)

	if dist <= detection_radius:
		if not player_in_sight:
			player_in_sight = true
			print("[DWELLER] PLAYER SPOTTED")
			path.clear()
			path_index = 0
			current_state = State.CHASE
	else:
		if player_in_sight:
			player_in_sight = false
			print("[DWELLER] PLAYER LOST")
			if current_state == State.CHASE:
				last_known_player_pos = player.global_position
				search_timer = search_duration
				current_state = State.SEARCH
				path.clear()
				path_index = 0


# =========================================================
# SIGNALS
# =========================================================
func _on_body_entered(body):
	if body.name == "Player":
		print("[DWELLER] Player entered detection")
		player_in_sight = true
		path.clear()
		path_index = 0
		current_state = State.CHASE


func _on_body_exited(body):
	if body.name == "Player":
		print("[DWELLER] Player exited detection")
		player_in_sight = false
		if current_state == State.CHASE:
			last_known_player_pos = player.global_position
			search_timer = search_duration
			current_state = State.SEARCH
			path.clear()
			path_index = 0


# =========================================================
# A STAR
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
		id_path.assign(astar.get_id_path(from_cell, path_target_cell))

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
		candidate_path.assign(astar.get_id_path(from_cell, candidate))
		if candidate_path.size() >= 2:
			print("[DWELLER] Target blocked -> nearest reachable: ", candidate)
			return [candidate, candidate_path]

	return []


# =========================================================
# MOVEMENT
# =========================================================
func _move_along_path(delta):
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
		var test = astar.get_id_path(origin, cell)
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
	if velocity.length() > 5:
		anim.play("run")
	else:
		anim.play("run")
