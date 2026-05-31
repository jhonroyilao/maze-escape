extends Node2D

const DWELLER_SCENE: PackedScene = preload("res://scenes/dweller.tscn")
const DWELLER_SCRIPT: Script = preload("res://scripts/dweller.gd")

const PLAYER_SAFE_RADIUS := 128.0
const DWELLER_SAFE_RADIUS := 96.0
const SPAWN_ATTEMPT_LIMIT := 300

@onready var tilemap: TileMap = $TileMap
@onready var player: Node2D = $Player
@onready var existing_dweller: CharacterBody2D = $dweller
@onready var camp: Area2D = get_node_or_null("Camp")

var rng := RandomNumberGenerator.new()
var spawned_dweller_positions: Array[Vector2] = []


func _ready() -> void:
	rng.randomize()
	_spawn_extra_dwellers()


func _spawn_extra_dwellers() -> void:
	var level_manager = get_node_or_null("/root/LevelManager")
	if level_manager == null:
		return

	var level_data = level_manager.get_active_level()
	var extra_count := int(level_data.get("extra_dweller_count", 0))
	if extra_count <= 0:
		return

	spawned_dweller_positions = [existing_dweller.global_position]
	for index in range(extra_count):
		var spawn_position := _pick_spawn_position()
		if spawn_position == Vector2.INF:
			push_warning("[DWELLER SPAWNER] No valid spawn found for extra dweller %s" % [index + 1])
			continue

		var dweller := DWELLER_SCENE.instantiate() as CharacterBody2D
		dweller.name = "dweller_extra_%s" % [index + 1]
		dweller.set_script(DWELLER_SCRIPT)
		dweller.global_position = spawn_position
		dweller.scale = existing_dweller.scale
		dweller.collision_layer = existing_dweller.collision_layer
		dweller.collision_mask = existing_dweller.collision_mask
		_add_roar_player(dweller)
		add_child(dweller)
		spawned_dweller_positions.append(spawn_position)


func _pick_spawn_position() -> Vector2:
	var used_rect := tilemap.get_used_rect()
	for attempt in range(SPAWN_ATTEMPT_LIMIT):
		var cell := Vector2i(
			rng.randi_range(used_rect.position.x, used_rect.end.x - 1),
			rng.randi_range(used_rect.position.y, used_rect.end.y - 1)
		)
		if not _is_walkable_cell(cell):
			continue

		var world_position := tilemap.to_global(tilemap.map_to_local(cell))
		if not _is_spawn_position_clear(world_position):
			continue

		return world_position

	return Vector2.INF


func _is_walkable_cell(cell: Vector2i) -> bool:
	var tile_data := tilemap.get_cell_tile_data(0, cell)
	if tile_data == null:
		return false

	return tile_data.get_collision_polygons_count(0) == 0


func _is_spawn_position_clear(world_position: Vector2) -> bool:
	if world_position.distance_to(player.global_position) < PLAYER_SAFE_RADIUS:
		return false
	if _is_inside_camp(world_position):
		return false
	for dweller_position in spawned_dweller_positions:
		if world_position.distance_to(dweller_position) < DWELLER_SAFE_RADIUS:
			return false
	return true


func _is_inside_camp(world_position: Vector2) -> bool:
	if camp == null:
		return false

	var shape_node := camp.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null or not shape_node.shape is RectangleShape2D:
		return false

	var rect_shape := shape_node.shape as RectangleShape2D
	var half_size := rect_shape.size * shape_node.global_scale.abs() * 0.5
	var center := shape_node.global_position
	return (
		world_position.x >= center.x - half_size.x
		and world_position.x <= center.x + half_size.x
		and world_position.y >= center.y - half_size.y
		and world_position.y <= center.y + half_size.y
	)


func _add_roar_player(dweller: Node) -> void:
	var roar := AudioStreamPlayer.new()
	roar.name = "roar"
	roar.bus = &"DragonSFX"
	dweller.add_child(roar)
