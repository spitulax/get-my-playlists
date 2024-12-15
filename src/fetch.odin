package get_my_playlists

import "base:runtime"
import "core:encoding/json"
import "core:log"

fetch_saved_albums :: proc(
    access_token: string,
    alloc := context.allocator,
) -> (
    data: json.Array,
    ok: bool,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)

    process :: proc(array: ^json.Array, response: string, access_token: string) -> (ok: bool) {
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
            album := object_get(item, {"album"}, json.Object) or_return
            obj["name"] = cast_json(album["name"], json.String) or_return
            obj["url"] = object_get(album, {"external_urls", "spotify"}, json.String) or_return
            append(array, json.clone_value(obj, (cast(^runtime.Raw_Dynamic_Array)array).allocator))
        }

        next_json := response_root["next"]
        switch next in next_json {
        case json.Null:
            return true
        case json.String:
            _, response2 := spotify_api_url(next, access_token, context.temp_allocator) or_return
            process(array, response2, access_token) or_return
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
    log.info("Requesting page", context.user_index, "of user albums")
    _, response := spotify_api("/me/albums", access_token, args, context.temp_allocator) or_return
    process(&data, response, access_token) or_return

    ok = true
    return
}

