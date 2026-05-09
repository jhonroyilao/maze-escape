extends CharacterBody2D

# ------------------------------------
# STATES
# ------------------------------------
enum State { PATROL, CHASE, SEARCH, CAMP_INVESTIGATION }
var current_state: State = State.PATROL

# ------------------------------------
# SETTINGS
# ------------------------------------
var base_speed := 80.0
var speed := base_speed
var detection_radius := 9999.0
var search_duration := 5.0
var patrol_wait_time := 1.5

# ------------------------------------
# REFERENCES
# ------------------------------------
@onready var anim := $AnimatedSprite2D
@onready var detection_area := $DetectionArea
var player: CharacterBody2D = null
var tilemap: TileMap = null

# ------------------------------------
# A* GRID
# ------------------------------------
var astar := AStarGrid2D.new()
var cell_size := Vector2(16, 16)
var maze_rect := Rect2i(0, 0, 59, 42)

# ------------------------------------
# RUNTIME VARS
# ------------------------------------
var path: Array[Vector2] = []
var path_index := 0

var last_known_player_pos := Vector2.ZERO
var search_timer := 0.0

var camp_target: Vector2 = Vector2.INF
var patrol_points: Array[Vector2] = []
var patrol_index := 0
var patrol_wait_timer := 0.0
var is_waiting_at_patrol := false

var repath_timer := 0.0
var debug_timer := 0.0

# ------------------------------------
# NIGHT MODE
# ------------------------------------
var is_night := false

# ===========================================================
# READY
# ===========================================================
func _ready():
	tilemap = get_parent().get_node("TileMap")
	player = get_parent().get_node("Player")

	_build_astar()
	_generate_patrol_points(6)

	detection_area.body_entered.connect(_on_body_entered)
	detection_area.body_exited.connect(_on_body_exited)

	anim.play("idle")

	print("Dweller position: ", global_position)
	print("Player found: ", player)

# ===========================================================
# PHYSICS LOOP
# ===========================================================
func _physics_process(delta: float):
	velocity.y = 0
	debug_timer += delta
	if debug_timer >= 1.0:
		debug_timer = 0.0
		print("State: ", current_state, " | Velocity: ", velocity, " | Path size: ", path.size(), " | Path index: ", path_index)

	_check_player_visibility()
	_apply_day_night()
	_run_behavior(delta)
	_move_along_path()
	_update_animation()

# ===========================================================
# ALWAYS LOOK FOR PLAYER
# ===========================================================
func _check_player_visibility():
	if player == null:
		return
	var dist = global_position.distance_to(player.global_position)
	if dist <= detection_radius:
		if current_state != State.CHASE:
			print("SWITCHING TO CHASE — dist: ", dist)
			current_state = State.CHASE
			path.clear()
			_set_path_to(player.global_position)
	else:
		if current_state == State.CHASE:
			print("Player out of range — SEARCH")
			last_known_player_pos = player.global_position
			search_timer = search_duration
			current_state = State.SEARCH
			path.clear()

# ===========================================================
# DAY / NIGHT
# ===========================================================
func _apply_day_night():
	if is_night:
		speed = base_speed * 1.6
	else:
		speed = base_speed

# ===========================================================
# RULE-BASED BEHAVIOR FSM
# ===========================================================
func _run_behavior(delta: float):
	match current_state:

		State.CHASE:
			if player:
				repath_timer += delta
				if repath_timer >= 0.3:
					repath_timer = 0.0
					_set_path_to(player.global_position)
				last_known_player_pos = player.global_position

		State.SEARCH:
			search_timer -= delta
			if search_timer <= 0.0:
				current_state = State.PATROL
				path.clear()
				_next_patrol_point()
			else:
				if path.is_empty():
					_set_path_to(last_known_player_pos)
				if _reached_target(last_known_player_pos):
					velocity = Vector2.ZERO

		State.CAMP_INVESTIGATION:
			if camp_target != Vector2.INF:
				if path.is_empty():
					_set_path_to(camp_target)
				if _reached_target(camp_target):
					camp_target = Vector2.INF
					current_state = State.PATROL
					path.clear()
					_next_patrol_point()

		State.PATROL:
			if is_waiting_at_patrol:
				patrol_wait_timer -= delta
				velocity = Vector2.ZERO
				if patrol_wait_timer <= 0.0:
					is_waiting_at_patrol = false
					_next_patrol_point()
			else:
				if patrol_points.is_empty():
					return
				var pt = patrol_points[patrol_index]
				if path.is_empty():
					_set_path_to(pt)
				if _reached_target(pt):
					is_waiting_at_patrol = true
					patrol_wait_timer = patrol_wait_time
					path.clear()

# ===========================================================
# DETECTION SIGNALS
# ===========================================================
func _on_body_entered(body: Node2D):
	if body.name == "Player":
		current_state = State.CHASE
		path.clear()
		_set_path_to(player.global_position)

func _on_body_exited(body: Node2D):
	if body.name == "Player":
		if current_state == State.CHASE:
			last_known_player_pos = player.global_position
			search_timer = search_duration
			current_state = State.SEARCH
			path.clear()

func notify_camp_activated(camp_world_pos: Vector2):
	if current_state != State.CHASE:
		camp_target = camp_world_pos
		current_state = State.CAMP_INVESTIGATION
		path.clear()
		_set_path_to(camp_target)

# ===========================================================
# A* PATHFINDING
# ===========================================================
func _build_astar():
	astar.region = maze_rect
	astar.cell_size = cell_size
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.update()

	var solid_count = 0
	var open_count = 0
	for x in range(maze_rect.size.x):
		for y in range(maze_rect.size.y):
			var cell = Vector2i(x, y)
			var tile_data = tilemap.get_cell_tile_data(0, cell)
			if tile_data == null:
				open_count += 1
			elif tile_data.get_collision_polygons_count(0) > 0:
				astar.set_point_solid(cell, true)
				solid_count += 1
			else:
				open_count += 1
	print("A* built — solid: ", solid_count, " open: ", open_count)

func _find_nearest_walkable(cell: Vector2i) -> Vector2i:
	for radius in range(1, 6):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var nearby = cell + Vector2i(dx, dy)
				var clamped = nearby.clamp(
					maze_rect.position,
					maze_rect.position + maze_rect.size - Vector2i(1, 1)
				)
				if not astar.is_point_solid(clamped):
					return clamped
	return cell

func _set_path_to(world_target: Vector2):
	var from_cell = tilemap.local_to_map(tilemap.to_local(global_position))
	var to_cell = tilemap.local_to_map(tilemap.to_local(world_target))

	from_cell = from_cell.clamp(
		maze_rect.position,
		maze_rect.position + maze_rect.size - Vector2i(1, 1)
	)
	to_cell = to_cell.clamp(
		maze_rect.position,
		maze_rect.position + maze_rect.size - Vector2i(1, 1)
	)

	if astar.is_point_solid(from_cell):
		from_cell = _find_nearest_walkable(from_cell)

	if astar.is_point_solid(to_cell):
		to_cell = _find_nearest_walkable(to_cell)

	var raw_path = astar.get_point_path(from_cell, to_cell)
	if raw_path.is_empty():
		return

	path.clear()
	path_index = 0

	for cell in raw_path:
		var world_pos = tilemap.to_global(tilemap.map_to_local(Vector2i(cell)))
		path.append(world_pos)

	print("Path generated: ", path.size(), " steps")

func _move_along_path():
	if path.is_empty() or path_index >= path.size():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var target = path[path_index]
	var dist = global_position.distance_to(target)
	
	# Force advance if stuck on this waypoint too long
	if dist < 12.0 or dist > 200.0:
		path_index += 1
		if path_index >= path.size():
			path.clear()
			return

	target = path[path_index]
	var direction = (target - global_position).normalized()
	velocity = direction * speed
	move_and_slide()

func _reached_target(world_pos: Vector2) -> bool:
	return global_position.distance_to(world_pos) < 16.0

# ===========================================================
# PATROL
# ===========================================================
func _generate_patrol_points(count: int):
	var my_cell = tilemap.local_to_map(tilemap.to_local(global_position))
	print("Dweller cell: ", my_cell, " is solid: ", astar.is_point_solid(my_cell))

	var walkable: Array[Vector2] = []
	for x in range(maze_rect.size.x):
		for y in range(maze_rect.size.y):
			var cell = Vector2i(x, y)
			if not astar.is_point_solid(cell):
				walkable.append(tilemap.to_global(tilemap.map_to_local(cell)))

	print("Walkable tiles found: ", walkable.size())
	walkable.shuffle()
	for i in range(min(count, walkable.size())):
		patrol_points.append(walkable[i])

	if not patrol_points.is_empty():
		_set_path_to(patrol_points[0])

func _next_patrol_point():
	if patrol_points.is_empty():
		return
	patrol_index = (patrol_index + 1) % patrol_points.size()
	_set_path_to(patrol_points[patrol_index])

# ===========================================================
# ANIMATION
# ===========================================================
func _update_animation():
	if velocity.length() > 0:
		anim.play("idle")
	else:
		anim.play("idle")
