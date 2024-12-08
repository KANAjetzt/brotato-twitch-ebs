extends "res://singletons/run_data.gd"


onready var Pasha_pubsub_sender = get_node("/root/ModLoader/Pasha-TwitchEBS/PubsubSender")


func reset(restart: bool = false) -> void:
	.reset(restart)
	if Pasha_pubsub_sender:
		Pasha_pubsub_sender.clear_all()


func add_item(item:ItemData, player_index:int) -> void:
	.add_item(item, player_index)
	Pasha_pubsub_sender.item_added(item)


func remove_item(item:ItemData, player_index:int, by_id:bool = false) -> void:
	.remove_item(item, player_index, by_id)
	Pasha_pubsub_sender.item_removed(item)


func add_weapon(weapon:WeaponData, player_index:int, is_selection:bool = false) -> WeaponData:
	var new_weapon := .add_weapon(weapon, player_index, is_selection)

	Pasha_pubsub_sender.weapon_added(weapon)
	return new_weapon


func remove_weapon(weapon:WeaponData, player_index:int)->int:
	var removed_weapon_tracked_value := .remove_weapon(weapon, player_index)
	Pasha_pubsub_sender.weapon_removed(weapon)
	return removed_weapon_tracked_value
