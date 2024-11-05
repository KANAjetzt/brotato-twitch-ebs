extends "res://ui/menus/shop/stats_container.gd"


onready var Pasha_pubsub_sender = get_node("/root/ModLoader/Pasha-TwitchEBS/PubsubSender")


func update_stats() -> void:
	.update_stats()

	Pasha_pubsub_sender.stats_update()
