package get_my_playlists

import "base:runtime"
import "core:encoding/json"
import "core:log"

fetch_name_url_objs :: proc(
    path: string,
    item_data_key: string,
    access_token: string,
    alloc := context.allocator,
) -> (
    data: json.Array,
    ok: bool,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)

    process :: proc(
        array: ^json.Array,
        item_data_key: string,
        response: string,
        access_token: string,
        loc: runtime.Source_Code_Location,
    ) -> (
        ok: bool,
    ) {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

        response_json, response_json_err := json.parse_string(
            response,
            allocator = context.temp_allocator,
        )
        if response_json_err != nil {
            log.error("Spotify API response is not a valid JSON")
            return false
        }

        response_root := cast_json(response_json, json.Object) or_return
        for item in (cast_json(response_root["items"], json.Array) or_return) {
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            obj := make(json.Object, 2, context.temp_allocator)
            album := object_get(item, {item_data_key}, json.Object) or_return
            obj["name"] = cast_json(album["name"], json.String) or_return
            obj["url"] = object_get(album, {"external_urls", "spotify"}, json.String) or_return
            append(array, json.clone_value(obj, (cast(^runtime.Raw_Dynamic_Array)array).allocator))
        }

        next_json := response_root["next"]
        switch next in next_json {
        case json.Null:
            return true
        case json.String:
            context.user_index += 1
            log.infof("Requesting page %d...", context.user_index, location = loc)
            _, response2 := spotify_api_url(next, access_token, context.temp_allocator) or_return
            process(array, item_data_key, response2, access_token, loc) or_return
        case json.Integer, json.Float, json.Boolean, json.Array, json.Object:
            log.error("Spotify API response is invalid")
            return false
        }

        return true
    }

    LIMIT := "50"
    args := make(map[string]string, 2, context.temp_allocator)
    args["limit"] = LIMIT
    args["offset"] = "0"

    data = make(json.Array, alloc)

    context.user_index = 1
    log.infof("Requesting page %d...", context.user_index, location = #location())
    _, response := spotify_api(path, access_token, args, context.temp_allocator) or_return
    process(&data, item_data_key, response, access_token, #location()) or_return

    ok = true
    return
}

fetch_liked_songs :: proc(
    access_token: string,
    alloc := context.allocator,
) -> (
    data: json.Array,
    ok: bool,
) {
    log.info("Requesting liked songs...")
    return fetch_name_url_objs("/me/tracks", "track", access_token, alloc)
}

fetch_saved_albums :: proc(
    access_token: string,
    alloc := context.allocator,
) -> (
    data: json.Array,
    ok: bool,
) {
    log.info("Requesting saved albums...")
    return fetch_name_url_objs("/me/albums", "album", access_token, alloc)
}

