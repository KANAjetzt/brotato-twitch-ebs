extends Node


const uuid_util = preload("res://mods-unpacked/Pasha-TwitchEBS/uuid.gd")
const PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME = "Pasha-TwitchEBS:PubsubSender"
const SEND_TIME = 3
const BATCH_SIZE = 5

enum SendAction { CLEAR_ALL, STATS_UPDATE, WEAPON_ADDED, WEAPON_REMOVED, ITEM_ADDED, IMAGE_UPLOAD, ITEM_REMOVED }

var is_started := false
var is_collect_data_enabled := false
var send_action_strings := {
	0: "clear_all",
	1: "stats_update",
	2: "weapon_added",
	3: "weapon_removed",
	4: "item_added",
	5: "image_upload",
	6: "item_removed"
}

var send_timer: Timer
var http_request: HTTPRequest
var is_http_request_processing := false

var update_queue_image := {}
var update_queue_image_current_id := ""

var update_queue_weapon := []
var update_queue_item := []
# Stats don't need a queue we always send the latest data
var update_stats := {}

var catch_up_store_weapons := {}
var catch_up_store_items := {}
var catch_up_store_stats := {}
var catch_up_store_images := {}
var catch_up_store_images_current_id := ''

var catch_up_index := 0
var catch_up_index_image := 0
var catch_up_index_image_chunk := 0

var is_catch_up := false
var is_catch_up_image := false

var url = "https://api.twitch.tv/helix/extensions/pubsub"


func _ready() -> void:
	add_send_timer()
	add_http_request()

	RunData.connect("stats_updated", self, "stats_update")
	TempStats.connect("temp_stats_updated", self, "stats_update")


func send_pubsub_request(data: String):
	if not $"/root".has_node("AuthHandler"):
		return

	var twitch_jwt = $"/root/AuthHandler".jwt

	if not twitch_jwt or twitch_jwt == "":
		return

	var twitch_broadcaster_id = $"/root/AuthHandler".channel_id

	var headers = []
	headers.push_back(str("Authorization: Bearer ", twitch_jwt))
	headers.push_back("Client-Id: %s" % $"/root/AuthHandler".client_id)
	headers.push_back("Content-Type:application/json")

	var body = to_json({"message": str(data), "broadcaster_id": twitch_broadcaster_id, "target": ["broadcast"]})

	var error = http_request.request(url, headers, true, HTTPClient.METHOD_POST, body)
	if error != OK:
		push_error("An error occurred in the HTTP request.")


func add_send_timer() -> void:
	send_timer = Timer.new()
	send_timer.name = "SendTimer"
	send_timer.wait_time = SEND_TIME
	send_timer.connect("timeout", self, "_send_timer_timeout")
	add_child(send_timer)
	send_timer.start(SEND_TIME)


func add_http_request() -> void:
	# Create an HTTP request node and connect its completion signal.
	http_request = HTTPRequest.new()
	add_child(http_request)
	http_request.connect("request_completed", self, "_http_request_completed")


func get_send_action_text(send_action: int) -> String:
	return send_action_strings[send_action]


func send(data: Array) -> void:
	send_pubsub_request(JSON.print(data))
	ModLoaderLog.info(JSON.print(data, "\t"), PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)


func get_catch_up_batch(batch_size_left := BATCH_SIZE, send_image := true, send_stats := false) -> Array:
	var batch := []
	var catch_up_store := []

	if send_image and not catch_up_store_images.empty():
		return get_catch_up_batch_image()

	# Get the catch_up_store array without images
	catch_up_store = get_catch_up_store_array(false)

	if catch_up_store.size() < batch_size_left:
		batch_size_left = catch_up_store.size()

	while batch_size_left > 0:
		var action: Dictionary = catch_up_store[catch_up_index]

		# Prevents potential doubling of stat updates.
		# If there is space left in the update batch, it's filled up with catch up data, and it's very likely it will double up on the stats update.
		if not send_stats and action.action == get_send_action_text(SendAction.STATS_UPDATE):
			catch_up_index = catch_up_index + 1 if not catch_up_index + 1 == catch_up_store.size() else 0
			if catch_up_store.size() == 1:
				break
			else:
				continue

		batch_size_left = batch_size_left - 1

		# Update item effect text
		if action.action == get_send_action_text(SendAction.ITEM_ADDED):
			var new_text_effects := get_text_item(action.data.id)
			if not new_text_effects.empty():
				action.data.effects = new_text_effects

		# Update weapon stats and effects text
		if action.action == get_send_action_text(SendAction.WEAPON_ADDED):
			var new_text := get_text_weapon(action.data.id)
			if not new_text.empty():
				var new_text_stats: String = new_text[0]
				var new_text_effects: String = new_text[1]

				action.data.stats = new_text_stats
				action.data.effects = new_text_effects

		batch.push_back(action)

		# Restart catch_up_index if we are at the end of the array
		catch_up_index = (catch_up_index + 1) % catch_up_store.size()

	return batch


func sender() -> void:
	if is_http_request_processing:
		return

	var batch := []
	var batch_size_left := BATCH_SIZE
	var send_data := {
		"id": "",
		"action": 0,
		"data": {},
	}
	var catch_up_stats := true

	if is_catch_up:
		ModLoaderLog.debug("Sending catch up batch", PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)
		batch = get_catch_up_batch(BATCH_SIZE, is_catch_up_image)
		batch_size_left = 0

		# Toggle image catch up
		is_catch_up_image = not is_catch_up_image

	# Update Stats
	if not update_stats.empty() and batch_size_left > 0:
		send_data.action = get_send_action_text(SendAction.STATS_UPDATE)
		send_data.data = update_stats
		batch.push_back(send_data.duplicate(true))
		catch_up_store_stats = send_data.duplicate(true)
		batch_size_left = batch_size_left - 1

		# Don't add stats to the catch up batch if we have fresh stats
		catch_up_stats = false

		update_stats = {}

	# Update Weapons
	for i in batch_size_left:
		if update_queue_weapon.empty():
			break
		var update_weapon: Array = update_queue_weapon.pop_front()
		send_data.id = uuid_util.v4()
		send_data.action = get_send_action_text(update_weapon[1])
		send_data.data = update_weapon[0]
		batch.push_back(send_data.duplicate(true))
		handle_catch_up_store_weapons(send_data.duplicate(true))
		batch_size_left = batch_size_left - 1

	# Update Items
	for i in batch_size_left:
		if update_queue_item.empty():
			break
		var update_item: Array = update_queue_item.pop_front()
		send_data.id = uuid_util.v4()
		send_data.action = get_send_action_text(update_item[1])
		if update_item[1] == SendAction.ITEM_ADDED:
			update_item[0].count += 1

			if update_item[0].is_cursed:
				update_item[0].id = "%s-cursed-%s" % [update_item[0].id, send_data.id]
		send_data.data = update_item[0]
		batch.push_back(send_data.duplicate(true))
		handle_catch_up_store_items(send_data.duplicate(true))
		batch_size_left = batch_size_left - 1

	# Upload Image
	for i in batch_size_left:
		if update_queue_image.empty():
			break

		var current_image := {}
		var current_image_chunk := {}

		if update_queue_image_current_id.empty() or not update_queue_image.has(update_queue_image_current_id):
			update_queue_image_current_id = update_queue_image.keys()[0]

		current_image = update_queue_image[update_queue_image_current_id]

		# If there are no more chunks the upload is done and we can erase the image entry
		if current_image.base64_chunks.empty():
			update_queue_image.erase(update_queue_image_current_id)
			update_queue_image_current_id = ""

			if update_queue_image.empty():
				break

			update_queue_image_current_id = update_queue_image.keys()[0]
			current_image = update_queue_image[update_queue_image_current_id]

		current_image_chunk = current_image.base64_chunks.pop_front()

		send_data.id = uuid_util.v4()
		send_data.action = get_send_action_text(SendAction.IMAGE_UPLOAD)
		send_data.data = {}
		send_data.data.item_id = current_image.item_id
		send_data.data.base64_chunk = current_image_chunk.string
		send_data.data.base64_chunk_index = current_image_chunk.index
		send_data.data.base64_chunk_count = current_image.base64_chunk_count

		batch.push_back(send_data.duplicate(true))

		handle_catch_up_store_images(send_data.duplicate(true))

		# Images take up the entire batch
		batch_size_left = 0
		break

	# If we have space left we can add catch up actions
	if batch_size_left > 0:
		ModLoaderLog.debug("Adding catch up batch", PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)
		var catch_up_batch := get_catch_up_batch(batch_size_left, false, catch_up_stats)
		batch.append_array(catch_up_batch)

	if not batch.empty():
		send(batch)


func resume() -> void:
	clear_all()

	for weapon_data in RunData.get_player_weapons(0):
		weapon_added(weapon_data)

	for item_data in RunData.get_player_items(0):
		item_added(item_data)

	stats_update(0)


# Immediately sends a clear_all action to the front-end
func clear_all() -> void:
	update_queue_weapon.clear()
	update_queue_item.clear()
	update_queue_image.clear()
	update_queue_image_current_id = ""
	catch_up_store_weapons.clear()
	catch_up_store_items.clear()
	catch_up_store_stats.clear()
	catch_up_store_images.clear()
	catch_up_index = 0
	catch_up_index_image = 0
	catch_up_index_image_chunk = 0

	send([{"action": get_send_action_text(SendAction.CLEAR_ALL), "data": {}}])


func item_added(item_data: ItemData) -> void:
	if not is_game_running():
		return

	var new_item_data := {}
	var new_item_icon_resource_path: String = item_data.icon.resource_path

	new_item_data.id = item_data.my_id
	new_item_data.tier = item_data.tier
	new_item_data.name = tr(item_data.name)
	new_item_data.effects = item_data.get_effects_text(0)
	new_item_data.count = 0
	new_item_data.is_cursed = item_data.is_cursed

	if not item_data.is_cursed:
		if catch_up_store_items.has(item_data.my_id):
			new_item_data.count = catch_up_store_items[item_data.my_id].data.count

		for item in update_queue_item:
			if item[0].id == item_data.my_id and not item[0].is_cursed:
				new_item_data.count += 1

	update_queue_item.push_back([new_item_data, SendAction.ITEM_ADDED])

	if new_item_icon_resource_path.begins_with("res://mods-unpacked/"):
		var image := Image.new()
		image.load(new_item_icon_resource_path)
		upload_image(item_data.my_id, image)


func item_removed(item: ItemData) -> void:
	if not is_game_running():
		return

	var item_data := {}

	item_data.id = item.my_id

	catch_up_index = max(catch_up_index - 1, 0)

	if catch_up_store_items.has(item_data.id):
		if catch_up_store_items[item_data.id].data.count == 1:
			catch_up_store_items.erase(item_data.id)
		else:
			catch_up_store_items[item_data.id].data.count -= 1

	update_queue_item.push_back([item_data, SendAction.ITEM_REMOVED])


# Remove a weapon with this id and tier
func weapon_removed(item_data: WeaponData) -> void:
	if not is_game_running():
		return

	var weapon_data := {}

	weapon_data.id = item_data.my_id
	weapon_data.tier = item_data.tier

	catch_up_index = max(catch_up_index - 1, 0)

	# If the item that was removed has not yet been sent, remove the weapon-added action and skip the remove action.
	# This way only the data about the newly added tier +1 weapon will be send.
	for i in update_queue_weapon.size():
		var data: Dictionary = update_queue_weapon[i][0]
		var send_action: int = update_queue_weapon[i][1]

		if (
			weapon_data.id == data.id and
			weapon_data.tier == data.tier and
			send_action == SendAction.WEAPON_ADDED
		):
			update_queue_weapon.remove(i)
			return

	# clear the catch_up_store
	if catch_up_store_weapons.has(weapon_data.id):
		catch_up_store_weapons[weapon_data.id].pop_back()

		if catch_up_store_weapons[weapon_data.id].size() == 0:
			catch_up_store_weapons.erase(weapon_data.id)

	update_queue_weapon.push_back([weapon_data, SendAction.WEAPON_REMOVED])


# Add a new weapon
func weapon_added(item_data: WeaponData) -> void:
	if not is_game_running():
		return

	var weapon_data := {}
	var new_weapon_icon_resource_path: String = item_data.icon.resource_path

	weapon_data.id = item_data.my_id
	weapon_data.weapon_id = item_data.weapon_id
	weapon_data.tier = item_data.tier
	weapon_data.name = tr(item_data.name)
	weapon_data.set = tr(ItemService.get_weapon_sets_text(item_data.sets))
	weapon_data.stats = item_data.get_weapon_stats_text(0)
	weapon_data.effects = item_data.get_effects_text(0)
	weapon_data.is_cursed = item_data.is_cursed

	update_queue_weapon.push_back([weapon_data, SendAction.WEAPON_ADDED])

	if new_weapon_icon_resource_path.begins_with("res://mods-unpacked/"):
		var image := Image.new()
		image.load(new_weapon_icon_resource_path)
		upload_image(item_data.weapon_id, image)


func stats_update(player_index: int = 0) -> void:
	if not is_game_running():
		return

	var stats_data := {}

	# Get all stats
	for effect_key in PlayerRunData.init_stats():
		var stat_value := Utils.get_stat(effect_key.to_lower(), player_index) as int

		stats_data[effect_key] = stat_value

	# Add the special snowflakes
	stats_data.trees = RunData.players_data[player_index].effects.trees
	stats_data.free_rerolls = RunData.players_data[player_index].effects.free_rerolls

	update_stats = stats_data


func upload_image(item_id: String, image: Image) -> void:
	if not is_game_running():
		return

	if is_image_processed(item_id):
		return

	var base64 := Marshalls.raw_to_base64(image.save_png_to_buffer())
	var base64_length := base64.length() as float
	# 4kb message body limit -> roughly 4096 chars
	var chunks := ceil(base64_length / 3500.0)
	var base64_chunk_size := ceil(base64_length / chunks)
	var base64_current_position := 0
	var base64_chunks := []
	var data := {
		"item_id": "",
		"base64_chunks": [],
		"base64_chunk_count": chunks,
	}

	ModLoaderLog.debug("Splitting base64 into %s chunks, with a length of %s per chunk." % [chunks, base64_chunk_size], PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)

	for chunk_index in chunks:
		var base64_sub := {
			"index": 0,
			"string": ""
		}

		# If it's the last chunk take the rest of the string
		if chunk_index == chunks - 1:
			base64_sub.string = base64.substr(base64_current_position, -1)
		else:
			base64_sub.string = base64.substr(base64_current_position, base64_chunk_size)

		base64_sub.index = chunk_index

		base64_chunks.push_back(base64_sub)
		base64_current_position = base64_current_position + base64_chunk_size

	data.item_id = item_id
	data.base64_chunks = base64_chunks

	update_queue_image[item_id] = data

	ModLoaderLog.debug("Completted image splitting.", PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)


# That can definitely be optimized but eh ¯\_ツ)_/¯
func get_catch_up_store_array(get_images := true, get_stats := true, get_weapons := true, get_items := true) -> Array:
	var catch_up_store_array := []

	# Stats
	if not catch_up_store_stats.empty() and get_stats:
		catch_up_store_array.push_back(catch_up_store_stats)

	# Weapons
	if not catch_up_store_weapons.empty() and get_weapons:
		for send_data_weapons in catch_up_store_weapons.values():
			for send_data_weapon in send_data_weapons:
				catch_up_store_array.push_back(send_data_weapon)

	# Items
	if not catch_up_store_items.empty() and get_items:
		catch_up_store_array.append_array(catch_up_store_items.values())

	# Images
	if not catch_up_store_images.empty() and get_images:
		for image_chunks in catch_up_store_images.values():
			catch_up_store_array.append_array(image_chunks)

	return catch_up_store_array


func handle_catch_up_store_items(send_data: Dictionary) -> void:
	catch_up_store_items[send_data.data.id] = send_data


func handle_catch_up_store_weapons(send_data: Dictionary) -> void:
	# If add action - add to catch up store
	if send_data.action == get_send_action_text(SendAction.WEAPON_ADDED):
		if not catch_up_store_weapons.has(send_data.data.id):
			catch_up_store_weapons[send_data.data.id] = []
		catch_up_store_weapons[send_data.data.id].push_back(send_data)

	# If delete action - remove weapon with this id from catch up store
	# Delete action is now handled directly in weapon_removed()
#	if send_data.action == get_send_action_text(SendAction.WEAPON_REMOVED):
#		catch_up_store_weapons[send_data.data.id].pop_back()


func handle_catch_up_store_images(send_data: Dictionary) -> void:
	if not catch_up_store_images.has(send_data.data.item_id):
		catch_up_store_images[send_data.data.item_id] = []

	catch_up_store_images[send_data.data.item_id].push_back(send_data)


func get_catch_up_batch_image() -> Array:
	var batch := []

	var catch_up_store_images_values = catch_up_store_images.values()
	var current_image: Array = catch_up_store_images_values[catch_up_index_image]
	var action: Dictionary = current_image[catch_up_index_image_chunk]

	batch.push_back(action)

	# If it's the last image chunk of the current image
	if catch_up_index_image_chunk + 1 == current_image.size():
		# Reset the chunk index
		catch_up_index_image_chunk = 0
		# Go to the next image
		catch_up_index_image = catch_up_index_image + 1 if not catch_up_index_image + 1 == catch_up_store_images_values.size() else 0
	else:
		catch_up_index_image_chunk = catch_up_index_image_chunk + 1

	return batch


# Can be optimized by saving a reference of the `ItemData` in the catch up store, so I don't have to hunt for it in `RunData`.
func get_text_item(id: String) -> String:
	for item_data in RunData.get_player_items(0):
		if item_data.my_id == id:
			return item_data.get_effects_text(0)

	return ""


# Returns [stats text, effects text]
# Can be optimized by saving a reference of the `WeaponData` in the catch up store, so I don't have to hunt for in `RunData`.
func get_text_weapon(id: String) -> Array:
	for weapon_data in RunData.get_player_weapons(0):
		if weapon_data.my_id == id:
			return [weapon_data.get_weapon_stats_text(0), weapon_data.get_effects_text(0)]

	return []


func is_game_running() -> bool:
	var main := get_node_or_null("/root/Main")
	var shop := get_node_or_null("/root/Shop")

	return main or shop


func is_image_processed(id: String) -> bool:
	if update_queue_image.has(id) or catch_up_store_images.has(id):
		return true

	return false


func _send_timer_timeout() -> void:
	if not is_game_running():
		return

	if not is_collect_data_enabled:
		ModLoaderLog.info("Data collection is disabled. Toggle data collection in the main menu.", PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME, true)
		return

	if not is_started:
		resume()
		is_started = true

	sender()
	# Toggle catch up request
	is_catch_up = not is_catch_up


func _http_request_completed(result, response_code, headers, body):
	var body_string: String = body.get_string_from_ascii()

	ModLoaderLog.debug("http_request_completed: \n %s" % body_string, PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)

	is_http_request_processing = false
