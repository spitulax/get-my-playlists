package get_my_playlists

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"

fetch_name_url_objs :: proc(
    url: string,
    item_data_key: string,
    access_token: string,
    alloc := context.allocator,
) -> (
    data: json.Array,
    ok: bool,
) {
    process :: proc(
        url: string,
        array: ^json.Array,
        item_data_key: string,
        access_token: string,
        alloc: runtime.Allocator,
    ) -> (
        ok: bool,
    ) {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

        context.user_index += 1
        fmt.printfln("Requesting page %d...", context.user_index)

        response := spotify_api(url, access_token, context.temp_allocator) or_return
        for item in (cast_json(response["items"], json.Array) or_return) {
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            obj := make(json.Object, 2, alloc)
            actual_item := object_get(item, {item_data_key}, json.Object) or_return
            object_insert(
                &obj,
                "name",
                cast_json(actual_item["name"], json.String) or_return,
                true,
            )
            object_insert(
                &obj,
                "url",
                object_get(actual_item, {"external_urls", "spotify"}, json.String) or_return,
                true,
            )
            append(array, obj)
        }

        next_json := response["next"]
        switch next in next_json {
        case json.Null:
            return true
        case json.String:
            process(next, array, item_data_key, access_token, alloc) or_return
        case json.Integer, json.Float, json.Boolean, json.Array, json.Object:
            log.error("Spotify API response is invalid")
            return false
        }

        return true
    }

    data = make(json.Array, alloc)
    context.user_index = 0
    process(url, &data, item_data_key, access_token, alloc) or_return

    ok = true
    return
}

fetch_user_playlists :: proc(
    access_token: string,
    alloc := context.allocator,
) -> (
    data: json.Object,
    ok: bool,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)

    process :: proc(
        url: string,
        object: ^json.Object,
        access_token: string,
        alloc: runtime.Allocator,
    ) -> (
        ok: bool,
    ) {
        runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

        context.user_index += 1
        fmt.printfln("Requesting page %d...", context.user_index)

        response := spotify_api(url, access_token, context.temp_allocator) or_return
        for item in (cast_json(response["items"], json.Array) or_return) {
            runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
            name := object_get(item, {"name"}, json.String) or_return
            fmt.println("Found playlist:", name)
            id := object_get(item, {"id"}, json.String) or_return
            object_insert(
                object,
                name,
                fetch_name_url_objs(
                    spotify_api_url(fmt.tprintf("/playlists/%s/tracks", id), common_args()),
                    "track",
                    access_token,
                    alloc,
                ) or_return,
            )
        }

        next_json := response["next"]
        switch next in next_json {
        case json.Null:
            return true
        case json.String:
            process(next, object, access_token, alloc) or_return
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

    data = make(json.Object, alloc)

    context.user_index = 0
    process(spotify_api_url("/me/playlists", common_args()), &data, access_token, alloc) or_return

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
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)
    return fetch_name_url_objs(
        spotify_api_url("/me/tracks", common_args()),
        "track",
        access_token,
        alloc,
    )
}

fetch_saved_albums :: proc(
    access_token: string,
    alloc := context.allocator,
) -> (
    data: json.Array,
    ok: bool,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)
    return fetch_name_url_objs(
        spotify_api_url("/me/albums", common_args()),
        "album",
        access_token,
        alloc,
    )
}

common_args :: proc(alloc := context.temp_allocator) -> map[string]string {
    LIMIT := "50"
    args := make(map[string]string, 2, alloc)
    args["limit"] = LIMIT
    args["offset"] = "0"
    return args
}

