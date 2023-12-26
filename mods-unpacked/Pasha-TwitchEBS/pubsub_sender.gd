extends Node


const uuid_util = preload("res://mods-unpacked/Pasha-TwitchEBS/uuid.gd")
const PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME = "Pasha-TwitchEBS:PubsubSender"
const SEND_TIME = 3
const BATCH_SIZE = 5

enum SendAction { CLEAR_ALL, STATS_UPDATE, WEAPON_ADDED, WEAPON_REMOVED, ITEM_ADDED, IMAGE_UPLOAD }

var send_action_strings := {
	0: "clear_all",
	1: "stats_update",
	2: "weapon_added",
	3: "weapon_removed",
	4: "item_added",
	5: "image_upload",
}

var send_timer: Timer
var http_request: HTTPRequest
var is_http_request_processing := false

# [[image_base64_chunk, image_base64_chunk], [image_base64_chunk, image_base64_chunk]]
var upload_queue_image := []
# {"item_id": "item_my_id", "base64_chunks": [image_base64_chunk, image_base64_chunk]}
var upload_queue_image_current := {}

var update_queue_weapon := []
var update_queue_item := {}
# Stats don't need a queue we always send the latest data
var update_stats := {}

var catch_up_store_weapons := {}
var catch_up_store_items := {}
var catch_up_store_stats := {}
var catch_up_store_images := []

var catch_up_index := 0
var catch_up_index_image := 0

var is_catch_up := false
var is_catch_up_image := false

var url = "https://api.twitch.tv/helix/extensions/pubsub"


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


func _ready() -> void:
	add_send_timer()
	add_http_request()

	RunData.connect("stats_updated", self, "stats_update")
	TempStats.connect("temp_stats_updated", self, "stats_update")


func add_send_timer() -> void:
	send_timer = Timer.new()
	send_timer.name = "Twitch_EBS_Dev_Get_Data_Timer"
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


func get_catch_up_batch(batch_size_left := BATCH_SIZE, send_image := true, send_stats := true) -> Array:
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

		if not send_stats and action.action == get_send_action_text(SendAction.STATS_UPDATE):
			catch_up_index = catch_up_index + 1 if not catch_up_index + 1 == catch_up_store.size() else 0
			if catch_up_store.size() == 1:
				break
			else:
				continue

		batch_size_left = batch_size_left - 1
		batch.push_back(action)
		# Restart catch_up_index if we are at the end of the array
		catch_up_index = catch_up_index + 1 if not catch_up_index + 1 == catch_up_store.size() else 0

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
		var update_item: Dictionary = update_queue_item.values()[0]
		update_queue_item.erase(update_item.id)
		send_data.id = uuid_util.v4()
		send_data.action = get_send_action_text(SendAction.ITEM_ADDED)
		send_data.data = update_item
		batch.push_back(send_data.duplicate(true))
		handle_catch_up_store_items(send_data.duplicate(true))
		batch_size_left = batch_size_left - 1

	# Upload Image
	for i in batch_size_left:
		if upload_queue_image.empty() and upload_queue_image_current.empty():
			break
		if upload_queue_image_current.has("base64_chunks") and upload_queue_image_current.base64_chunks.empty():
			upload_queue_image_current = {}
			break
		send_data.id = uuid_util.v4()
		if not upload_queue_image_current.has("base64_chunks") or upload_queue_image_current.base64_chunks.empty():
			send_data.action = get_send_action_text(SendAction.IMAGE_UPLOAD)
			upload_queue_image_current = upload_queue_image.pop_front()
		elif upload_queue_image_current.base64_chunks.size() == 1:
			send_data.action = get_send_action_text(SendAction.IMAGE_UPLOAD)
		else:
			send_data.action = get_send_action_text(SendAction.IMAGE_UPLOAD)

		var image_base64_data: Dictionary = upload_queue_image_current.base64_chunks.pop_front()
		send_data.data = {
			"item_id": upload_queue_image_current.item_id,
			"base64_chunk": image_base64_data.string,
			"base64_chunk_index": image_base64_data.index,
			"base64_chunk_count": upload_queue_image_current.base64_chunk_count
			}
		batch.push_back(send_data.duplicate(true))
		catch_up_store_images.push_back(send_data.duplicate(true))
		# Set it to 0 because this will take up all the space
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

	for weapon_data in RunData.weapons:
		weapon_added(weapon_data)

	for item_data in RunData.items:
		item_added(item_data)

	stats_update()


# Imidiatly sends a clear_all action to the front end
func clear_all() -> void:
	update_queue_weapon.clear()
	update_queue_item.clear()
	upload_queue_image.clear()
	upload_queue_image_current.clear()
	catch_up_store_weapons.clear()
	catch_up_store_items.clear()
	catch_up_store_stats.clear()
	catch_up_store_images.clear()
	catch_up_index = 0
	catch_up_index_image = 0

	send([{"action": get_send_action_text(SendAction.CLEAR_ALL), "data": {}}])


func item_added(item_data: ItemData) -> void:
	var new_item_data := {}
	var new_item_icon_resource_path: String = item_data.icon.resource_path
	var item_count := get_item_count(item_data.my_id)

	new_item_data.id = item_data.my_id
	new_item_data.tier = item_data.tier
	new_item_data.name = tr(item_data.name)
	new_item_data.effects = item_data.get_effects_text()
	new_item_data.count = 1 if item_count == -1 else item_count + 1

	# Add new `item_data` to the item queue if there is none with this ID or if the new count is higher.
	if not update_queue_item.has(item_data.my_id) or update_queue_item[item_data.my_id].count < new_item_data.count:
		update_queue_item[item_data.my_id] = new_item_data

	if new_item_icon_resource_path.begins_with("res://mods-unpacked/"):
		var image := Image.new()
		image.load(new_item_icon_resource_path)
		upload_image(item_data.my_id, image)


# Remove a weapon with this id and tier
func weapon_removed(item_data: WeaponData) -> void:
	var weapon_data := {}

	weapon_data.id = item_data.my_id
	weapon_data.tier = item_data.tier

	update_queue_weapon.push_back([weapon_data, SendAction.WEAPON_REMOVED])


# Add a new weapon
func weapon_added(item_data: WeaponData) -> void:
	var weapon_data := {}
	var new_weapon_icon_resource_path: String = item_data.icon.resource_path

	weapon_data.id = item_data.my_id
	weapon_data.tier = item_data.tier
	weapon_data.name = tr(item_data.name)
	weapon_data.set = tr(ItemService.get_weapon_sets_text(item_data.sets))
	weapon_data.stats = item_data.get_weapon_stats_text()
	weapon_data.effects = item_data.get_effects_text()

	update_queue_weapon.push_back([weapon_data, SendAction.WEAPON_ADDED])

	if new_weapon_icon_resource_path.begins_with("res://mods-unpacked/"):
		var image := Image.new()
		image.load(new_weapon_icon_resource_path)
		upload_image(item_data.weapon_id, image)


func stats_update() -> void:
	var stats_data := {}

	# Get all stats
	for effect_key in RunData.init_stats():
		var stat_value := Utils.get_stat(effect_key.to_lower()) as int

		stats_data[effect_key] = stat_value

	# Add the special snowflakes
	stats_data.trees = RunData.effects.trees
	stats_data.free_rerolls = RunData.effects.free_rerolls

	update_stats = stats_data


# TODO: What if only one chunk is created? Currently I send a image_upload image_upload_start and image_upload_end action to handle different states.
# TODO: Only upload the same image once!
func upload_image(item_id: String, image: Image) -> void:
	var base64 := Marshalls.raw_to_base64(image.save_png_to_buffer())
	var base64_length := base64.length()
	# 4kb message body limit -> roughly 4096 chars
	var chunks := ceil(base64_length / 3500)
	var base64_chunk_size := floor(base64_length / chunks)
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

	upload_queue_image.push_back(data)

	ModLoaderLog.debug("Completted image splitting.", PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)


# That can definitely be optimized but eh ¯\_ツ)_/¯
func get_catch_up_store_array(get_images := true, get_stats := true, get_weapons := true, get_items := true) -> Array:
	var catch_up_store_array := []

	if not catch_up_store_stats.empty() and get_stats:
		catch_up_store_array.push_back(catch_up_store_stats)

	if not catch_up_store_weapons.empty() and get_weapons:
		for send_data_weapons in catch_up_store_weapons.values():
			for send_data_weapon in send_data_weapons:
				catch_up_store_array.push_back(send_data_weapon)

	if not catch_up_store_items.empty() and get_items:
		catch_up_store_array.append_array(catch_up_store_items.values())

	if not catch_up_store_images.empty() and get_images:
		catch_up_store_array.append_array(catch_up_store_images)

	return catch_up_store_array


# This might look a bit weird, but I wanted to keep the structure of the `send_data` the same for all action types.
# So, I add the `item_count` to the data prop.
func handle_catch_up_store_items(send_data: Dictionary) -> void:
	catch_up_store_items[send_data.data.id] = send_data


func get_item_count(item_id: String) -> int:
	if update_queue_item.has(item_id):
		return update_queue_item[item_id].count

	if catch_up_store_items.has(item_id):
		return catch_up_store_items[item_id].data.count

	return -1


func handle_catch_up_store_weapons(send_data: Dictionary) -> void:
	# If add action add to catch up store
	if send_data.action == get_send_action_text(SendAction.WEAPON_ADDED):
		if not catch_up_store_weapons.has(send_data.data.id):
			catch_up_store_weapons[send_data.data.id] = []
		catch_up_store_weapons[send_data.data.id].push_back(send_data)

	# If delete remove weapon with this id from catch up store
	if send_data.action == get_send_action_text(SendAction.WEAPON_REMOVED):
		catch_up_store_weapons[send_data.data.id].pop_back()


func get_catch_up_batch_image() -> Array:
	var batch := []

	batch.push_back(catch_up_store_images[catch_up_index_image])

	# Restart catch_up_index_image if we are at the end of the array
	catch_up_index_image = catch_up_index_image + 1 if not catch_up_index_image + 1 == catch_up_store_images.size() else 0

	return batch


func _send_timer_timeout() -> void:
	sender()
	# Toggle catch up request
	is_catch_up = not is_catch_up


func _http_request_completed(result, response_code, headers, body):
	var body_string: String = body.get_string_from_ascii()

	ModLoaderLog.debug("http_request_completed: \n %s" % body_string, PASHA_TWITCHEBS_PUBSUBSENDER_LOG_NAME)

	is_http_request_processing = false