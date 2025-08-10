package get_my_playlists

import "base:runtime"
import "core:crypto"
import "core:terminal/ansi"
import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import path "core:path/filepath"
import "core:strings"
import "core:time"
import sp "deps:subprocess.odin"

PROG_NAME :: #config(PROG_NAME, "")
PROG_VERSION :: #config(PROG_VERSION, "")

REDIRECT_PORT :: 3000
SCOPES :: "playlist-read-private user-library-read"

// TODO: Multithreading

g_curl: sp.Program

start :: proc() -> (ok: bool) {
    curl_err: sp.Error
    g_curl, curl_err = sp.program_check("curl")
    if curl_err != nil {
        log.error("`curl` was not found:", curl_err)
        return false
    }
    defer sp.program_destroy(&g_curl)

    parse_args() or_return

    return true
}

parse_args :: proc() -> (ok: bool) {
    @(require_results)
    next_args :: proc(args: ^[]string, loc := #caller_location) -> (arg: string, ok: bool) {
        if len(args^) <= 0 {
            when ODIN_DEBUG {
                log.error("Expected more arguments", location = loc)
            } else {
                fmt.eprintln("Expected more arguments")
            }
            ok = false
            return
        }
        curr := args[0]
        args^ = args[1:]
        return curr, true
    }

    args := os.args
    _ = next_args(&args) or_return
    subcommand := next_args(&args) or_return
    switch subcommand {
    case "auth":
        client_id := next_args(&args) or_return
        client_secret := next_args(&args) or_return
        auth(client_id, client_secret) or_return
    case "fetch":
        access_token := next_args(&args) or_return
        out_file := next_args(&args) or_return
        fetch_to_file(access_token, out_file) or_return
    case "download":
        access_token, in_file, out_dir: string
        for {
            arg := next_args(&args) or_return
            switch arg {
            case "-i":
                in_file = next_args(&args) or_return
            case "-a":
                access_token = next_args(&args) or_return
            case:
                out_dir = arg
            }

            if out_dir != "" && (in_file != "" || access_token != "") {
                break
            }
        }
        download(access_token, in_file, out_dir) or_return
    case "--help", "-h":
        usage()
    case "--version":
        fmt.println(PROG_NAME, PROG_VERSION)
    case:
        fmt.eprintln("Invalid subcommand:", subcommand)
        ok = false
        return
    }

    ok = true
    return
}

auth :: proc(client_id: string, client_secret: string) -> (ok: bool) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    context.random_generator = crypto.random_generator()
    state := uuid.to_string(uuid.generate_v4(), context.temp_allocator)
    query := make(map[string]string, 5, context.temp_allocator)
    query["client_id"] = client_id
    query["response_type"] = "code"
    query["redirect_uri"] = fmt.tprintf("http://localhost:%v", REDIRECT_PORT)
    query["scope"] = SCOPES
    query["state"] = state
    params := query_string_stringify(query, context.temp_allocator)
    url := fmt.tprintf("https://accounts.spotify.com/authorize?%s", params)
    ansi_graphic(ansi.BOLD)
    fmt.print("Open this in your web browser: ")
    ansi_graphic(ansi.FG_BLUE)
    fmt.println(url)
    ansi_reset()
    ansi_graphic(ansi.BOLD)
    fmt.println(
        "If you don't get redirected to localhost:3000, please read the instruction in `" +
        PROG_NAME +
        " --help`",
    )
    ansi_reset()

    addr := net.Endpoint{net.IP4_Loopback, REDIRECT_PORT}
    read_res := listen_and_read(addr, context.temp_allocator) or_return
    request := at_split_lines(read_res, 0, context.temp_allocator)
    path := at_split(request, " ", 1, context.temp_allocator)
    query_str := at_split(path, "?", 1, context.temp_allocator)
    queries := strings.split(query_str, "&", context.temp_allocator)
    code: Maybe(string)
    for query in queries {
        split := strings.split_n(query, "=", 2, context.temp_allocator)
        name := split[0]
        value := split[1]

        switch name {
        case "state":
            if value != state {
                log.error("Authorisation failed: State mismatch")
                return false
            }
        case "code":
            code = value
        case "error":
            log.errorf("Authorisation failed: %s", value)
            return false
        }
    }
    if _, ook := code.?; !ook {
        log.error("Authorisation failed: Authorisation code does not exist")
        return false
    }

    auth_val := base64.encode(
        transmute([]byte)fmt.tprintf("%s:%s", client_id, client_secret),
        allocator = context.temp_allocator,
    )

    URL :: "https://accounts.spotify.com/api/token"
    result := run_curl(
        {
            "-s",
            "-X",
            "POST",
            "-w",
            "\\n%{http_code}",
            URL,
            "-H",
            "Content-Type: application/x-www-form-urlencoded",
            "-H",
            fmt.tprintf("Authorization: Basic %s", auth_val),
            "-d",
            fmt.tprintf(
                "grant_type=authorization_code&code=%s&redirect_uri=%s",
                code.?,
                fmt.tprintf("http://localhost:%v", REDIRECT_PORT),
            ),
        },
        "Authorisation failed",
        context.temp_allocator,
    ) or_return
    response := strings.split_lines(string(result.stdout), context.temp_allocator)
    json_data, json_data_err := json.parse_string(response[0], allocator = context.temp_allocator)
    json_root, json_root_ok := cast_json(json_data, json.Object)
    status := response[1]
    if len(response) != 2 || json_data_err != nil || !json_root_ok {
        log.error("Authorisation failed: Malformed response")
        return false
    }

    switch status {
    case "200":
        if (cast_json(json_root["token_type"], json.String) or_return) != "Bearer" ||
           (cast_json(json_root["scope"], json.String) or_return) != SCOPES {
            log.error("Authorisation failed: Incorrect response")
            return false
        }

        ansi_graphic(ansi.BOLD)
        fmt.print("Access Token: ")
        ansi_graphic(ansi.FG_BLUE)
        fmt.println(cast_json(json_root["access_token"], json.String) or_return)
        ansi_reset()
        ansi_graphic(ansi.BOLD)
        fmt.println(
            "Expires in:",
            cast(time.Duration)(cast_json(json_root["expires_in"], json.Float) or_return) *
            time.Second,
        )
        ansi_reset()

        return true
    case "400":
        log.error(
            "Authorisation failed: Failed to request an access token:",
            json_root["error_description"],
        )
        return false
    case "404":
        log.error("Authorisation failed: URL does not exist:", URL)
        return false
    case:
        log.error("Authorisation failed: Unknown response status:", status)
        return false
    }
}

fetch :: proc(access_token: string, alloc := context.allocator) -> (data: json.Object, ok: bool) {
    obj := make(json.Object, 3, alloc)
    defer if !ok {
        json.destroy_value(obj, alloc)
    }
    ansi_graphic(ansi.BOLD);fmt.println("Requesting Liked Songs...");ansi_reset()
    object_insert(&obj, "liked_songs", fetch_liked_songs(access_token) or_return)
    fmt.println()
    ansi_graphic(ansi.BOLD);fmt.println("Requesting Playlists...");ansi_reset()
    object_insert(&obj, "playlists", fetch_user_playlists(access_token) or_return)
    fmt.println()
    ansi_graphic(ansi.BOLD);fmt.println("Requesting Saved Albums...");ansi_reset()
    object_insert(&obj, "saved_albums", fetch_saved_albums(access_token) or_return)

    return obj, true
}

fetch_to_file :: proc(access_token, out_file: string) -> (ok: bool) {
    data := fetch(access_token) or_return
    defer json.destroy_value(data)
    marshal_to_file(out_file, data) or_return
    return true
}

download :: proc(access_token, in_file, out_dir: string) -> (ok: bool) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    from_file := in_file != ""
    file_content: []byte
    data: json.Object
    if from_file {
        file_err: os.Error
        file_content, file_err = os.read_entire_file_or_err(in_file)
        if file_err != nil {
            log.errorf("Failed to read `%s`: %v", in_file, file_err)
            return false
        }
        defer delete(file_content)
        data_json, json_err := json.parse(file_content)
        if json_err != nil {
            log.errorf("Failed parse JSON from `%s`: %v", in_file, json_err)
            return false
        }
        data = cast_json(data_json, json.Object) or_return
    } else {
        if access_token != "" {
            unreachable()
        }
        data = fetch(access_token) or_return
    }
    defer json.destroy_value(data)

    mkdir_if_not_exists(out_dir) or_return

    //data_path := path.join({out_dir, "data.json"}, context.temp_allocator)
    //if from_file {
    //    if err := os.write_entire_file_or_err(data_path, file_content); err != nil {
    //        log.errorf("Could not write to `%s`: %v", data_path, err)
    //        return false
    //    }
    //} else {
    //    marshal_to_file(data_path, data) or_return
    //}

    music_dir := path.join({out_dir, ".music"}, context.temp_allocator)
    mkdir_if_not_exists(music_dir)

    cmd, cmd_err := sp.command_make("spotdl")
    if cmd_err != nil {
        log.error("Failed to create `spotdl` command:", cmd_err)
        return false
    }
    defer sp.command_destroy(&cmd)
    sp.command_append(&cmd, "--preload")
    //sp.command_append(&cmd, "--format", "mp3")
    //sp.command_append(&cmd, "--overwrite", "skip")
    sp.command_append(&cmd, "--print-errors")
    sp.command_append(&cmd, "--playlist-numbering")
    sp.command_append(&cmd, "--save-file", "music.spotdl")
    //sp.command_append(&cmd, "--output", "{track-id}.{output-ext}")
    //sp.command_append(&cmd, "download")
    sp.command_append(&cmd, "save")
    for _, v in cast_json(data["liked_songs"], json.Object) or_return {
        sp.command_append(&cmd, object_get(v, {"url"}, json.String) or_return)
    }

    old_dir := os.get_current_directory(context.temp_allocator)
    chdir(music_dir) or_return
    spotdl_result, spotdl_err := sp.command_run_sync(cmd, alloc = context.temp_allocator)
    if spotdl_err != nil {
        log.error("Failed to run spotdl:", spotdl_err)
        return false
    }
    if !sp.result_success(spotdl_result) {
        log.error("`spotdl` exited with status:", spotdl_result.exit)
        return false
    }
    chdir(old_dir) or_return

    return true
}

usage :: proc() {
    fmt.println(
        PROG_NAME,
        `<subcommand> [args...]"

Subcommands:
    auth <client_id> <client_secret>
        Authenticate user and give the access token
    fetch <access_token> <out_file>
        Fetch the playlist data as a JSON file

How to authenticate and get the access token:
- Create an app
    - Go to https://developer.spotify.com/dashboard
    - Fill "Redirect URIs" with "http://localhost:3000"
    - Tick off "Web API"
    - Anything else doesn't matter, fill it whatever you want
- Authenticate your user
    - Go to dashboard and select your new app
    - Click "Settings"
    - Copy both the client ID and client secret
    - Run: ./get-my-playlists auth "<client_id>" "<client_secret>"
`,
    )
}

main :: proc() {
    ok: bool
    defer if !ok {
        os.exit(1)
    }
    defer free_all(context.temp_allocator)
    when ODIN_DEBUG {
        mem_track: mem.Tracking_Allocator
        mem.tracking_allocator_init(&mem_track, context.allocator)
        context.allocator = mem.tracking_allocator(&mem_track)
        defer {
            fmt.print("\033[1;31m")
            if len(mem_track.allocation_map) > 0 {
                fmt.eprintfln("### %v unfreed allocations ###", len(mem_track.allocation_map))
                for _, v in mem_track.allocation_map {
                    fmt.eprintfln(" -> %v bytes from %v (%v)", v.size, v.location, v.memory)
                }
            }
            if len(mem_track.bad_free_array) > 0 {
                fmt.eprintfln("### %v bad frees ###", len(mem_track.bad_free_array))
                for v in mem_track.bad_free_array {
                    fmt.eprintfln(" -> %p from %v", v.memory, v.location)
                }
            }
            fmt.print("\033[0m")
            mem.tracking_allocator_destroy(&mem_track)
        }
    } else {
        _ :: mem
    }

    logger := log.create_console_logger(log.Level.Debug when ODIN_DEBUG else log.Level.Info)
    defer log.destroy_console_logger(logger)
    context.logger = logger

    sp.default_flags_enable({.Echo_Commands_Debug, .Use_Context_Logger})

    ok = start()
}

