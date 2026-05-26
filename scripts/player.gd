extends CharacterBody2D

const SPEED = 60.0

func _physics_process(delta: float) -> void:
	# Get input for all directions
	var input_vector = Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	)

	# Normalize so diagonal movement is not faster
	if input_vector != Vector2.ZERO:
		input_vector = input_vector.normalized()

	# Apply movement
	velocity = input_vector * SPEED

	# Move the character
	move_and_slide()
	
	
	


func _on_body_entered(body_rid: RID, body: Node2D, body_shape_index: int, local_shape_index: int) -> void:
	pass # Replace with function body.
