extends "res://singletons/temp_stats.gd"


onready var Pasha_pubsub_sender = get_node("/root/ModLoader/Pasha-TwitchEBS/PubsubSender")

func set_stat(stat_name: String, value: int, player_index: int) -> void:
	.set_stat(stat_name, value, player_index)
	# For now only one player is supported
	if player_index == 0:
		Pasha_pubsub_sender.stats_update(player_index)
