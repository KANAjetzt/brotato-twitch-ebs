extends "res://singletons/run_data.gd"


onready var Pasha_pubsub_sender = get_node("/root/ModLoader/Pasha-TwitchEBS/PubsubSender")


func reset(restart: bool = false) -> void:
	.reset(restart)
	if restart:
		Pasha_pubsub_sender.resume()


func add_item(item:ItemData, player_index:int) -> void:
	.add_item(item, player_index)
	Pasha_pubsub_sender.item_added(item)


func add_weapon(weapon:WeaponData, player_index:int, is_selection:bool = false) -> WeaponData:
	var new_weapon := .add_weapon(weapon, player_index, is_selection)

	Pasha_pubsub_sender.weapon_added(weapon)
	return new_weapon


func remove_weapon(weapon:WeaponData, player_index:int)->int:
	var removed_weapon_tracked_value := .remove_weapon(weapon, player_index)
	Pasha_pubsub_sender.weapon_removed(weapon)
	return removed_weapon_tracked_value
