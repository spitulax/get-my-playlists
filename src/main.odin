package get_my_playlists

import "base:runtime"
import "core:crypto"
import "core:encoding/ansi"
import "core:encoding/base64"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import sp "deps:subprocess.odin"

PROG_NAME :: #config(PROG_NAME, "")
PROG_VERSION :: #config(PROG_VERSION, "")

REDIRECT_PORT :: 3000
SCOPES :: "playlist-read-private user-library-read"

start :: proc() -> (ok: bool) {
    if len(os.args) < 2 {
        usage()
        return false
    }

    error := true
    switch os.args[1] {
    case "auth":
        if len(os.args) == 4 {
            client_id := os.args[2]
            client_secret := os.args[3]
            auth(client_id, client_secret) or_return
            error = false
        }
    case "--help", "-h":
        usage()
        return true
    case "--version":
        fmt.println(PROG_NAME, PROG_VERSION)
        return true
    case:
        fmt.eprintln("Invalid subcommand:", os.args[1])
    }

    if error {
        usage()
        return false
    }

    return true
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

    curl := sp.program("curl")
    auth_val := base64.encode(
        transmute([]byte)fmt.tprintf("%s:%s", client_id, client_secret),
        allocator = context.temp_allocator,
    )

    result, result_err := sp.run_prog_sync(
        curl,
        {
            "-s",
            "-X",
            "POST",
            "-w",
            "\\n%{http_code}",
            "https://accounts.spotify.com/api/token",
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
        .Capture,
        alloc = context.temp_allocator,
    )
    if result_err != nil {
        log.error("Authorisation failed: Failed to run `curl`:", result_err)
        return false
    }
    if !sp.process_result_success(result) {
        log.error("Authorisation failed: `curl` exited with", result.exit)
        return false
    }
    response := strings.split_lines(result.stdout, context.temp_allocator)
    json_data, json_data_err := json.parse(
        transmute([]byte)(response[0]),
        allocator = context.temp_allocator,
    )
    json_root, json_root_ok := json_data.(json.Object)
    status := response[1]
    if len(response) != 2 || json_data_err != nil || !json_root_ok {
        log.error("Authorisation failed: Malformed response")
        return false
    }

    switch status {
    case "200":
        if json_root["token_type"].(json.String) != "Bearer" ||
           json_root["scope"].(json.String) != SCOPES {
            log.error("Authorisation failed: Incorrect response")
            return false
        }

        ansi_graphic(ansi.BOLD)
        fmt.print("Access Token: ")
        ansi_graphic(ansi.FG_BLUE)
        fmt.println(json_root["access_token"].(json.String))
        ansi_reset()
        ansi_graphic(ansi.BOLD)
        fmt.println(
            "Expires in:",
            cast(time.Duration)json_root["expires_in"].(json.Float) * time.Second,
        )
        ansi_reset()

        return true
    case "400":
        log.error(
            "Authorisation failed: Failed to request an access token:",
            json_root["error_description"],
        )
        return false
    case:
        log.error("Authorisation failed: Unknown response status:", status)
        return false
    }
}

usage :: proc() {
    fmt.println(
        PROG_NAME,
        `<subcommand> [args...]"

Subcommands:
    auth <client_id> <client_secret>
        Authenticate user and give the access token
    fetch <access_token>
        Fetch the playlist data as a JSON string

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
    defer os.exit(!ok)
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
                    fmt.eprintfln(" -> %v bytes from %v", v.size, v.location)
                }
            }
            if len(mem_track.bad_free_array) > 0 {
                fmt.eprintfln("### %v bad frees ###", len(mem_track.bad_free_array))
                for x in mem_track.bad_free_array {
                    fmt.eprintfln(" -> %p from %v", x.memory, x.location)
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

