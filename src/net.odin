package get_my_playlists

import "base:runtime"
import "core:log"
import "core:mem"
import "core:net"

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
    buf := make([dynamic]byte, 1 * mem.Kilobyte, alloc)
    defer if !ok {
        delete(buf)
    }
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
    return string(buf[:]), true
}

write_tcp :: proc(socket: net.TCP_Socket, buf: []byte) -> (ok: bool) {
    if bytes_written, write_err := net.send_tcp(socket, buf);
       write_err != nil || bytes_written != len(buf) {
        log.errorf("Failed to write to socket: %v", write_err)
        return false
    }
    return true
}

