package get_my_playlists

import "base:runtime"
import "core:encoding/ansi"
import "core:fmt"
import "core:io"
import "core:net"
import "core:strings"

query_string_stringify :: proc(queries: map[string]string, alloc := context.allocator) -> string {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(alloc == context.temp_allocator)
    sb := strings.builder_make(alloc)
    i := 0
    for k, v in queries {
        if i > 0 {
            fmt.sbprint(&sb, "&")
        }
        fmt.sbprintf(
            &sb,
            "%s=%s",
            net.percent_encode(k, context.temp_allocator),
            net.percent_encode(v, context.temp_allocator),
        )
        i += 1
    }
    return strings.to_string(sb)
}


ansi_reset :: proc() {
    fmt.print(ansi.CSI + ansi.RESET + ansi.SGR, flush = false)
}

ansi_graphic :: proc(options: ..string) {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
    fmt.print(
        ansi.CSI,
        concat_string_sep(options, ";", context.temp_allocator),
        ansi.SGR,
        sep = "",
        flush = false,
    )
}


concat_string_sep :: proc(strs: []string, sep: string, alloc := context.allocator) -> string {
    sb := strings.builder_make(alloc)
    for str, i in strs {
        if i > 0 {
            fmt.sbprint(&sb, sep)
        }
        fmt.sbprint(&sb, str)
    }
    return strings.to_string(sb)
}

append_concat_string_sep :: proc(w: io.Writer, strs: []string, sep: string) {
    for str, i in strs {
        if i > 0 {
            fmt.wprint(w, sep)
        }
        fmt.wprint(w, str)
    }
}

at_split :: proc(s: string, sep: string, idx: int, alloc := context.allocator) -> string {
    strs := strings.split_n(s, sep, idx + 2)
    defer delete(strs)
    return strings.clone(strs[idx], alloc)
}

at_split_lines :: proc(s: string, idx: int, alloc := context.allocator) -> string {
    strs := strings.split_lines_n(s, idx + 2)
    defer delete(strs)
    return strings.clone(strs[idx], alloc)
}

