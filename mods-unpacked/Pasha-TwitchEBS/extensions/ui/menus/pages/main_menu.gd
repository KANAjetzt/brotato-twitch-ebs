extends "res://ui/menus/pages/main_menu.gd"


var twitch_buttons
var twitch_button_auth: Button
var twitch_button_send_data: CheckButton

onready var Pasha_pubsub_sender = get_node("/root/ModLoader/Pasha-TwitchEBS/PubsubSender")


func _ready() -> void:
	if not $"/root".has_node("AuthHandler"):
		return

	var auth_handler = $"/root/AuthHandler"
	var buttons_left: Node = get_node("HBoxContainer/ButtonsLeft")

	twitch_buttons = load("res://mods-unpacked/Pasha-TwitchEBS/content/TwitchAuthButtons.tscn").instance()
	twitch_button_auth = twitch_buttons.get_node("TwitchAuthButton")
	twitch_button_send_data = twitch_buttons.get_node("TwitchSendDataToggle")


	if auth_handler.jwt and not auth_handler.jwt == "":
		call_deferred("make_button_green")
		twitch_button_send_data.pressed = Pasha_pubsub_sender.is_collect_data_enabled

	buttons_left.add_child(twitch_buttons)

	Pasha_pubsub_sender.is_started = false

	auth_handler.connect("auth_in_progress", self, "_on_auth_in_progress")
	auth_handler.connect("auth_failure", self, "_on_auth_failure")
	auth_handler.connect("auth_success", self, "_on_auth_success")
	twitch_button_auth.connect("pressed", self, "start_twitch_auth")
	twitch_button_send_data.connect("toggled", self, "_on_twitch_button_send_data_toggled")

func start_twitch_auth() -> void:
	if not $"/root".has_node("AuthHandler"):
		return

	twitch_button_auth.release_focus()

	$"/root/AuthHandler".get_auth_code()


func _on_auth_failure() -> void:
	var stylebox_flat = twitch_button_auth.get_stylebox("normal").duplicate()
	stylebox_flat.bg_color = Color(1, 0, 0, 0.8)
	twitch_button_auth.add_stylebox_override("normal", stylebox_flat)


func _on_auth_in_progress() -> void:
	var stylebox_flat = twitch_button_auth.get_stylebox("normal").duplicate()
	stylebox_flat.bg_color = Color(1, 1, 0, 0.8)
	twitch_button_auth.add_stylebox_override("normal", stylebox_flat)


func _on_auth_success() -> void:
	make_button_green()
	twitch_button_send_data.pressed = true


func make_button_green() -> void:
	var stylebox_flat = twitch_button_auth.get_stylebox("normal").duplicate()
	stylebox_flat.bg_color = Color(0, 1, 0, 0.8)
	twitch_button_auth.add_stylebox_override("normal", stylebox_flat)


func _on_twitch_button_send_data_toggled(pressed: bool) -> void:
	Pasha_pubsub_sender.is_collect_data_enabled = pressed
