extends CharacterBody2D

enum State {
	PATROL,
	CHASE,
	SEARCH,
	CAMP_INVESTIGATION
}

var current_state: State = State.PATROL
var attack_radius := 10.0
var base_speed := 100.0
var speed := base_speed
var detection_radius := 180.0
var search_duration := 8.0

@onready var anim := $AnimatedSprite2D
@onready var detection_area := $DetectionArea
@onready var debug_label := $Label

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

var debug_timer := 0.0
var stuck_timer := 0.0
var last_position := Vector2.ZERO
var stuck_threshold := 4.0

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

	anim.play("idle")
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
	_run_behavior(delta)
	_move_along_path()
	_update_animation()
	_debug_tick(delta)


# =========================================================
# CATCH PLAYER -> GAME OVER                              ++
# =========================================================
func _check_catch_player():
	if player == null or caught:
		return

	if current_state == State.CHASE:
		var dist = global_position.distance_to(player.global_position)
		if dist <= attack_radius:
			caught = true
			print("[DWELLER] PLAYER CAUGHT -> GAME OVER")
			# ++ Change this path to your actual Game Over scene
			get_tree().change_scene_to_file("res://GameOver.tscn")


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
	astar.region = maze_rect
	astar.cell_size = cell_size
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.update()

	var solid_count := 0
	for x in range(maze_rect.size.x):
		for y in range(maze_rect.size.y):
			var cell = Vector2i(x, y)
			var tile_data = tilemap.get_cell_tile_data(0, cell)
			if tile_data:
				if tile_data.get_collision_polygons_count(0) > 0:
					astar.set_point_solid(cell, true)
					solid_count += 1

	print("[DWELLER] ASTAR READY | solids: ", solid_count)


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
	if astar.is_point_solid(to_cell):
		to_cell = _find_nearest_walkable(to_cell)

	var raw_path = astar.get_point_path(from_cell, to_cell)

	if raw_path.is_empty():
		print("[DWELLER] NO PATH")
		path.clear()
		path_index = 0
		return

	path.clear()
	path_index = 0
	for point in raw_path:
		path.append(point)

	print("[DWELLER] Path created: ", path.size(), " nodes")


# =========================================================
# WALKABLE CELL
# =========================================================
func _find_nearest_walkable(cell: Vector2i) -> Vector2i:
	for radius in range(1, 5):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				var check = cell + Vector2i(dx, dy)
				if astar.is_in_boundsv(check):
					if not astar.is_point_solid(check):
						return check
	return cell


# =========================================================
# MOVEMENT
# =========================================================
func _move_along_path():
	if _path_exhausted():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	while path_index < path.size():
		if global_position.distance_to(path[path_index]) < 18.0:
			path_index += 1
		else:
			break

	if _path_exhausted():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var target = path[path_index]
	var dir = target - global_position

	if dir.length() < 2.0:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	velocity = dir.normalized() * speed
	move_and_slide()


# =========================================================
# PATROL POINTS
# =========================================================
func _generate_patrol_points(count: int):
	patrol_points.clear()
	var walkable: Array[Vector2i] = []
	for x in range(maze_rect.size.x):
		for y in range(maze_rect.size.y):
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
		var test = astar.get_point_path(origin, cell)
		if test.size() > 0:
			patrol_points.append(tilemap.to_global(tilemap.map_to_local(cell)))
		if checked >= 60:
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
		if moved < 5.0:
			print("[DWELLER] STUCK -> REPATH")
			path.clear()
			path_index = 0
			match current_state:
				State.CHASE:
					if player:
						_set_path_to(player.global_position)
				State.SEARCH:
					var offset = Vector2(randf_range(-64, 64), randf_range(-64, 64))
					_set_path_to(last_known_player_pos + offset)
				State.PATROL:
					_advance_patrol()
		last_position = global_position


# =========================================================
# ANIMATION
# =========================================================
func _update_animation():
	if velocity.length() > 5:
		anim.play("run")
	else:
		anim.play("run")
