package get_my_playlists

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:strings"
import sp "deps:subprocess.odin"

listen_and_read :: proc(
    endpoint: net.Endpoint,
    alloc := context.allocator,
) -> (
    res: string,
    ok: bool,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)

    sock, sock_err := net.listen_tcp(endpoint)
    if sock_err != nil {
        log.errorf("Failed to listen on %s: %v", net.to_string(endpoint), sock_err)
        ok = false
        return
    }
    defer net.close(sock)
    log.info("Listening on", net.to_string(endpoint))

    client, _, client_err := net.accept_tcp(sock)
    if client_err != nil {
        log.errorf("Failed to accept socket: %v", client_err)
        ok = false
        return
    }
    defer net.close(client)

    log.info("Connection established")
    return read_tcp(client, alloc)
}

read_tcp :: proc(socket: net.TCP_Socket, alloc := context.allocator) -> (res: string, ok: bool) {
    buf := make([dynamic]byte, 1 * mem.Kilobyte)
    defer delete(buf)
    off := 0
    for {
        bytes_read, read_err := net.recv_tcp(socket, buf[off:])
        if read_err != nil {
            log.errorf("Failed to read from socket: %v", read_err)
            ok = false
            return
        }
        if bytes_read == 0 {
            break
        }
        write_tcp(socket, buf[off:off + bytes_read]) or_return
        off += bytes_read
        if off >= len(buf) {
            resize(&buf, 2 * len(buf))
        }
    }
    return strings.clone_from_bytes(buf[:off], alloc), true
}

write_tcp :: proc(socket: net.TCP_Socket, buf: []byte) -> (ok: bool) {
    if bytes_written, write_err := net.send_tcp(socket, buf);
       write_err != nil || bytes_written != len(buf) {
        log.errorf("Failed to write to socket: %v", write_err)
        return false
    }
    return true
}

run_curl :: proc(
    args: []string,
    err_prefix: string = "",
    alloc := context.allocator,
) -> (
    result: sp.Result,
    ok: bool,
) {
    result_err: sp.Error
    result, result_err = sp.program_run(
        g_curl,
        args,
        {output = .Capture, zero_env = true},
        alloc = alloc,
    )
    if result_err != nil {
        log.errorf(
            "%s%sFailed to run `curl`: %v",
            err_prefix,
            ": " if len(err_prefix) > 0 else "",
            result_err,
        )
        ok = false
        return
    }
    defer if !ok {
        sp.result_destroy(&result, alloc)
    }
    if !sp.result_success(result) {
        log.errorf(
            "%s%s`curl` exited with status %v:\n%s",
            err_prefix,
            ": " if len(err_prefix) > 0 else "",
            result.exit,
            string(result.stderr),
        )
        ok = false
        return
    }
    return result, true
}

spotify_api :: proc(
    url: string,
    access_token: string,
    alloc := context.allocator,
) -> (
    response: json.Object,
    ok: bool,
) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)
    ERR_PREFIX :: "Spotify API call failed"

    result := run_curl(
        {
            "-s",
            "-w",
            "\\n%{http_code}",
            url,
            "-H",
            fmt.tprint("Authorization: Bearer", access_token),
        },
        ERR_PREFIX,
        context.temp_allocator,
    ) or_return

    output := strings.split_lines(string(result.stdout), context.temp_allocator)
    if len(output) < 2 {
        log.error(ERR_PREFIX + ": Invalid response")
        ok = false
        return
    }
    response_str := output[0]
    status := output[len(output) - 1]
    error := true
    switch status {
    case "200":
        error = false
    case "401":
        log.error(ERR_PREFIX + ": Bad or expired token")
    case "403":
        log.error(
            ERR_PREFIX +
            ": Bad OAuth request (wrong consumer key, bad nonce, expired timestamp...)",
        )
    case "429":
        log.error(ERR_PREFIX + ": The app has exceeded its rate limits")
    case "404":
        log.error(ERR_PREFIX + ": URL does not exist:", url)
    case:
        log.error(ERR_PREFIX + ": Unknown response:", status)
    }
    if error {
        ok = false
        return
    }

    response_json, response_err := json.parse_string(response_str, allocator = alloc)
    if response_err != nil {
        log.error(ERR_PREFIX + ": Spotify API response is not a valid JSON")
        ok = false
        return
    }
    response = cast_json(response_json, json.Object) or_return

    return response, true
}

spotify_api_url :: proc(
    path: string,
    args: map[string]string,
    alloc := context.temp_allocator,
) -> string {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)
    return fmt.aprintf(
        "https://api.spotify.com/v1%s?%s",
        path,
        query_string_stringify(args, context.temp_allocator),
        allocator = alloc,
    )
}

