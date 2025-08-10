package get_my_playlists

import "base:runtime"
import "core:terminal/ansi"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:net"
import "core:os"
import "core:strings"

String_Slice :: string

g_marshal_opt := json.Marshal_Options {
    spec             = json.Specification.JSON,
    pretty           = true,
    use_spaces       = true,
    spaces           = 2,
    sort_maps_by_key = true,
}

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

cast_json :: proc(
    value: json.Value,
    $T: typeid,
    loc := #caller_location,
) -> (
    new_val: T,
    ok: bool,
) {
    if new_val, ok = value.(T); !ok {
        log.errorf("JSON object cannot be converted to `%v`", typeid_of(T), location = loc)
        ok = false
        return
    }
    return new_val, true
}

_object_get_internal:: proc(value: json.Value, path: []string, loc := #caller_location) -> (res: json.Value, key_name: string, ok: bool) {
    if len(path) <= 0 {
        log.error("`path` is empty", location = loc)
        ok = false
        return
    }

    cur_value := value
    prev_obj: json.Object
    prev_key := ""
    for i in -1 ..< len(path) {
        key := path[i] if i >= 0 else "<root>"
        if i >= 0 {
            cur_value_ok: bool
            if cur_value, cur_value_ok = prev_obj[key]; !cur_value_ok {
                log.errorf("`%s` does not exist in `%s`", key, prev_key, location = loc)
                ok = false
                return
            }
        }

        if i < len(path) - 1 {
            prev_obj_ok: bool
            if prev_obj, prev_obj_ok = cast_json(cur_value, json.Object, loc); !prev_obj_ok {
                log.errorf("`%s` is not an object, cannot index it", key, location = loc)
                ok = false
                return
            }
        } else {
            return cur_value, key, true
        }
        prev_key = key
    }
    unreachable()
}

object_get_generic :: proc(value: json.Value, path: []string, loc := #caller_location) -> (res: json.Value, ok: bool) {
    res, _ = _object_get_internal(value, path, loc) or_return
    return res, true
}

object_get :: proc(value: json.Value, path: []string, $T: typeid, loc := #caller_location) -> (res: T, ok: bool) {
    object, key := _object_get_internal(value, path, loc) or_return
    res_ok: bool
    if res, res_ok = cast_json(object, T, loc); !res_ok {
        log.errorf("`%s` cannot be converted to `%v`", key, typeid_of(T), location = loc)
        ok = false
        return
    }
    return res, true
}

object_insert :: proc(
    self: ^json.Object,
    key: string,
    value: json.Value,
    clone_value: bool = false,
    loc := #caller_location,
) {
    alloc := (cast(^runtime.Raw_Map)self).allocator
    if elem, ok := self[key]; ok {
        json.destroy_value(elem, loc = loc)
        delete_key(self, key)
    }
    self[strings.clone(key, alloc, loc)] = json.clone_value(value, alloc) if clone_value else value
}

mkdir_if_not_exists :: proc(path: string) -> (ok: bool) {
    if os.exists(path) && !os.is_dir(path) {
        log.errorf("`%s` already exists but it is not a directory", path)
        return false
    } else if !os.exists(path) {
        if err := os.make_directory(path); err != nil {
            log.errorf("Failed to create directory `%s`: %v", path, err)
            return false
        }
    }
    return true
}

marshal_to_file :: proc(path: string, value: any) -> (ok: bool) {
    marshal_data, marshal_err := json.marshal(value, g_marshal_opt)
    if marshal_err != nil {
        log.error("Failed to marshal data:", marshal_err)
        return false
    }
    defer delete(marshal_data)
    if err := os.write_entire_file_or_err(path, marshal_data); err != nil {
        log.errorf("Failed to write to `%s`: %v", path, err)
        return false
    }
    return true
}

chdir :: proc(path: string) -> (ok: bool) {
    if err := os.set_current_directory(path); err != nil {
        log.error("Failed to change directory:", err)
        return false
    }
    return true
}

