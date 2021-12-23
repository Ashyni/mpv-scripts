--[[
This script uses the lavfi cropdetect filter to automatically insert a crop filter with appropriate parameters for the
currently playing video, the script run continuously by default (mode 4).

The workflow is as follows: We observe two main events, vf-metadata and time-pos changes.
    vf-metadata are stored sequentially in buffer with time-pos being updated at every frame,
    then process to check and store trusted values to speed up future change for the current video.
    It will automatically crop the video as soon as a meta change is validated.

The default options can be overridden by adding script-opts-append=<script_name>-<parameter>=<value> into mpv.conf
    script-opts-append=dynamic_crop-mode=0
    script-opts-append=dynamic_crop-ratios=2.4 2.39 2 4/3 (quotes aren't needed like below)

List of available parameters (For default values, see <options>)：

mode: [0-4] 0 disable, 1 on-demand, 2 one-shot, 3 dynamic-manual, 4 dynamic-auto
    Mode 1 and 3 requires using the shortcut to start, 2 and 4 have an automatic start.
Shortcut "C" (shift+c) to control the script.
The first press maintains the cropping and disables the script, a second pressure eliminates the cropping 
and a third pressure is necessary to restart the script.
    Mode = 1-2, single cropping on demand, stays active until a valid cropping is apply.
    Mode = 3-4, start / stop dynamic cropping.

prevent_change_mode: [0-2] - 0 any, 1 keep-largest, 2 keep-lowest - The prevent_change_timer is trigger after a change,
    to disable this, set prevent_change_timer to 0.

resize_windowed: [true/false] - False, prevents the window from being resized, but always applies cropping,
    this function always avoids the default behavior to resize the window at the source size, in windowed/maximized mode.

segmentation: % [0.0-n] e.g. 0.5 for 50% - Extra time to allow new metadata to be segmented instead of being continuous.
    By default, new_known_ratio_timer is validated with 5 sec accumulated over 7.5 sec elapsed and
    new_fallback_timer with 20 sec accumulated over 30 sec elapsed.
    to disable this, set 0.

correction: % [0.0-1] e.g. 0.6 for 60% - Size minimum of collected meta (in percent based on source), to attempt a correction.
    to disable this, set 1.
]] --
require "mp.msg"
require "mp.options"

local options = {
    -- behavior
    mode = 4, -- [0-4] more details above.
    start_delay = 0, -- delay in seconds used to skip intro (usefull with mode 2)
    prevent_change_timer = 0, -- seconds
    prevent_change_mode = 2, -- [0-2], disable with 'prevent_change_timer = 0'
    resize_windowed = true,
    fast_change_timer = 1, -- seconds
    new_known_ratio_timer = 5, -- seconds
    new_fallback_timer = 20, -- seconds, >= 'new_known_ratio_timer', disable with 0
    ratios = "2.4 2.39 2.35 2.2 2 1.85 16/9 5/3 1.5 4/3 1.25 9/16", -- list separated by space
    ratios_extra_px = 2, -- even number, pixel added to check with the ratios list and offsets
    segmentation = 0.5, -- %, 0 will approved only a continuous metadata (strict)
    correction = 0.6, -- %, -- TODO auto value with trusted meta
    -- filter, see https://ffmpeg.org/ffmpeg-filters.html#cropdetect for details
    detect_limit = 24, -- is the maximum use, increase it slowly if lighter black are present
    detect_round = 2, -- even number
    detect_reset = 1, -- minimum 1
    detect_skip = 1, -- minimum 1, default 2 (new ffmpeg build since 12/2020)
    -- verbose
    debug = false
}
read_options(options)

if options.mode == 0 then
    mp.msg.info("mode = 0, disable script.")
    return
end

-- forward declaration
local cleanup, on_toggle
local applied, buffer, collected, last_collected, limit, source, stats
-- label
local label_prefix = mp.get_script_name()
local labels = {
    crop = string.format("%s-crop", label_prefix),
    cropdetect = string.format("%s-cropdetect", label_prefix)
}
-- state (boolean)
local in_progress, seeking, paused, toggled, filter_missing, filter_inserted
-- option
local time_pos = {}
local prevent_change_timer = options.prevent_change_timer * 1000
local fast_change_timer = options.fast_change_timer * 1000
local new_known_ratio_timer = options.new_known_ratio_timer * 1000
local new_fallback_timer = options.new_fallback_timer * 1000
local fallback = new_fallback_timer >= new_known_ratio_timer
local cropdetect_skip = string.format(":skip=%d", options.detect_skip)

local function is_trusted_offset(offset, axis)
    for _, v in pairs(stats.trusted_offset[axis]) do
        if math.abs(offset - v) <= options.ratios_extra_px then return true end
    end
    return false
end

local function is_filter_present(label)
    local filters = mp.get_property_native("vf")
    for _, filter in pairs(filters) do if filter["label"] == label then return true end end
    return false
end

local function is_cropable()
    for _, track in pairs(mp.get_property_native('track-list')) do
        if track.type == 'video' and track.selected then return not track.albumart end
    end
    return false
end

local function remove_filter(label)
    if is_filter_present(label) then mp.command(string.format("no-osd vf remove @%s", label)) end
end

local function insert_cropdetect_filter()
    if toggled or paused then return end
    -- "vf pre" cropdetect / "vf append" crop, in a proper order
    local function command()
        return mp.command(string.format("no-osd vf pre @%s:lavfi-cropdetect=limit=%d/255:round=%d:reset=%d%s",
                                        labels.cropdetect, limit.current, options.detect_round, options.detect_reset,
                                        cropdetect_skip))
    end
    if not command() then
        cropdetect_skip = ""
        if not command() then
            mp.msg.error("Does vf=help as #1 line in mvp.conf return libavfilter list with crop/cropdetect in log?")
            filter_missing = true
            cleanup()
            return
        end
    end
    filter_inserted = true
end

local function compute_meta(meta)
    meta.whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y)
    meta.offset = {x = meta.x - (source.w - meta.w) / 2, y = meta.y - (source.h - meta.h) / 2}
    meta.mt, meta.mb, meta.ml, meta.mr = meta.y, source.h - meta.h - meta.y, meta.x, source.w - meta.w - meta.x
    meta.is_source = meta.whxy == source.whxy
    meta.is_invalid = meta.h < 0 or meta.w < 0
    meta.is_trusted_offsets = is_trusted_offset(meta.offset.x, "x") and is_trusted_offset(meta.offset.y, "y")
    meta.time = {buffer = 0, overall = 0}
    -- check aspect ratio with the known list
    if not meta.is_invalid and meta.w >= source.w * .9 or meta.h >= source.h * .9 then
        for ratio in string.gmatch(options.ratios, "%S+%s?") do
            for a, b in string.gmatch(ratio, "(%d+)/(%d+)") do ratio = a / b end
            local height = math.floor((meta.w * 1 / ratio) + .5)
            if math.abs(height - meta.h) <= options.ratios_extra_px + 1 then -- ratios_extra_px + 1 for odd meta
                meta.is_known_ratio = true
                break
            end
        end
    end
    return meta
end

local function osd_size_change(orientation)
    local prop_maximized = mp.get_property("window-maximized")
    local prop_fullscreen = mp.get_property("fullscreen")
    local osd = mp.get_property_native("osd-dimensions")
    if prop_fullscreen == "no" then
        -- keep window width or height to avoid reset to source size when cropping
        if prop_maximized == "yes" or not options.resize_windowed then
            mp.set_property("geometry", string.format("%sx%s", osd.w, osd.h))
        else
            if orientation then
                mp.set_property("geometry", string.format("%s", osd.w))
            else
                mp.set_property("geometry", string.format("x%s", osd.h))
            end
        end
    end
end

local function print_debug(meta, type_, label)
    if options.debug then
        if type_ == "detail" then
            print(string.format("%s, %s | Offset X:%s Y:%s | limit:%s", label, meta.whxy, meta.offset.x, meta.offset.y,
                                limit.current))
        end
        if not type_ then print(meta) end
    end

    if type_ == "stats" and stats and stats.trusted then
        mp.msg.info("Meta Stats:")
        local read_maj_offset = {x = "", y = ""}
        for axis, _ in pairs(read_maj_offset) do
            for _, v in pairs(stats.trusted_offset[axis]) do
                read_maj_offset[axis] = read_maj_offset[axis] .. v .. " "
            end
        end
        mp.msg.info(string.format("Trusted Offset - X:%s| Y:%s", read_maj_offset.x, read_maj_offset.y))
        for whxy, table_ in pairs(stats.trusted) do
            if stats.trusted[whxy] then
                mp.msg.info(string.format("%s | offX=%s offY=%s | applied=%s overall=%s last_seen=%s", whxy,
                                          table_.offset.x, table_.offset.y, table_.applied, table_.time.overall / 1000,
                                          table_.time.last_seen / 1000))
            end
        end
        mp.msg.info("Buffer - total: " .. buffer.index_total,
                    buffer.time_total / 1000 .. "sec, unique_meta: " .. buffer.unique_meta .. " | known_ratio:",
                    buffer.index_known_ratio, buffer.time_known / 1000 .. "sec")
        if options.debug and stats.buffer then
            for whxy, table_ in pairs(stats.buffer) do
                mp.msg.info(string.format("- %s | offX=%s offY=%s | time.buffer=%ssec known_ratio=%s", whxy,
                                          table_.offset.x, table_.offset.y, table_.time.buffer / 1000,
                                          table_.is_known_ratio))
            end
            for pos, table_ in pairs(buffer.ordered) do
                mp.msg.info(string.format("-- %s %s", pos, table_[1].whxy))
            end
        end
    end
end

local function is_trusted_margin(whxy)
    local data = {count = 0}
    for _, axis in pairs({"mt", "mb", "ml", "mr"}) do
        data[axis] = math.abs(collected[axis] - stats.trusted[whxy][axis])
        if data[axis] == 0 then data.count = data.count + 1 end
    end
    return data
end

local function adjust_limit(meta)
    local limit_current = limit.current
    if meta.is_source then -- increase limit
        limit.change = 1
        if limit.current + limit.step * limit.up <= options.detect_limit then
            limit.current = limit.current + limit.step * limit.up
        else
            limit.current = options.detect_limit
        end
    elseif not meta.is_invalid and -- stable limit
        (last_collected == collected or last_collected and math.abs(collected.w - last_collected.w) <= 2 and
            math.abs(collected.h - last_collected.h) <= 2) then -- math.abs <= 2 to help stabilize odd metadata
        limit.change = 0
    else -- decrease limit
        limit.change = -1
        if limit.current > 0 then
            if limit.current - limit.step >= 0 then
                limit.current = limit.current - limit.step
            else
                limit.current = 0
            end
        end
    end
    return limit_current ~= limit.current
end

local function check_stability(current_)
    local found
    if options.detect_round <= 4 and not current_.is_source and stats.trusted[current_.whxy] then
        for _, table_ in pairs(stats.trusted) do
            if current_ ~= table_ and
                (not found and table_.time.overall > current_.time.overall * 1.1 or found and table_.time.overall >
                    found.time.overall * 1.1) and math.abs(current_.w - table_.w) <= 4 and
                math.abs(current_.h - table_.h) <= 4 then found = table_ end
        end
    end
    return found
end

local function time_to_cleanup_buffer(time_1, time_2) return time_1 > time_2 * (1 + options.segmentation) end

local function process_metadata(event, time_pos_)
    in_progress = true -- prevent event race

    local elapsed_time = time_pos_ - time_pos.insert
    print_debug(collected, "detail", "Collected")
    time_pos.insert = time_pos_

    -- init stats.buffer[whxy]
    if not stats.buffer[collected.whxy] then
        stats.buffer[collected.whxy] = collected
        buffer.unique_meta = buffer.unique_meta + 1
    end
    -- add collected meta to the buffer
    if buffer.index_total == 0 or buffer.ordered[buffer.index_total][1] ~= collected then
        table.insert(buffer.ordered, {collected, elapsed_time})
        buffer.index_total = buffer.index_total + 1
        buffer.index_known_ratio = buffer.index_known_ratio + 1
    elseif last_collected == collected then
        buffer.ordered[buffer.index_total][2] = buffer.ordered[buffer.index_total][2] + elapsed_time
    end
    collected.time.overall = collected.time.overall + elapsed_time
    collected.time.buffer = collected.time.buffer + elapsed_time
    buffer.time_total = buffer.time_total + elapsed_time
    if buffer.index_known_ratio > 0 then buffer.time_known = buffer.time_known + elapsed_time end

    -- add new offset to trusted_offset list
    if stats.buffer[collected.whxy] and fallback and collected.time.buffer >= new_fallback_timer then
        local add_new_offset = {}
        for _, axis in pairs({"x", "y"}) do
            add_new_offset[axis] = not collected.is_invalid and not is_trusted_offset(collected.offset[axis], axis)
            if add_new_offset[axis] then table.insert(stats.trusted_offset[axis], collected.offset[axis]) end
        end
    end

    -- reset last_seen before correction
    if stats.trusted[collected.whxy] and collected.time.last_seen < 0 then collected.time.last_seen = 0 end

    -- use current as main meta that can be collected/corrected/stabilized
    local current = collected

    -- correction with trusted meta for fast change in dark/ambiguous scene
    if not current.is_invalid and not stats.trusted[current.whxy] and
        (current.w > source.w * options.correction and current.h > source.h * options.correction) then
        -- find closest meta already applied
        local closest, in_between = {}, false
        for whxy in pairs(stats.trusted) do
            local diff = is_trusted_margin(whxy)
            -- break if we have the same position between two sets of margin
            if closest.whxy and closest.whxy ~= whxy and diff.count == closest.count and math.abs(diff.mt - diff.mb) ==
                math.abs(closest.mt - closest.mb) and math.abs(diff.ml - diff.mr) == math.abs(closest.ml - closest.mr) then
                in_between = true
                break
            end
            if not closest.whxy and diff.count >= 2 or closest.whxy and diff.count >= closest.count and diff.mt +
                diff.mb <= closest.mt + closest.mb and diff.ml + diff.mr <= closest.ml + closest.mr then
                closest.mt, closest.mb, closest.ml, closest.mr = diff.mt, diff.mb, diff.ml, diff.mr
                closest.count, closest.whxy = diff.count, whxy
            end
        end
        -- check if the corrected data is already applied
        if closest.whxy and not in_between and closest.whxy ~= applied.whxy then
            current = stats.trusted[closest.whxy]
        end
    end

    -- stabilization of odd/unstable meta
    local stabilized = check_stability(current)
    if stabilized then
        current = stabilized
        print_debug(current, "detail", "\\ Stabilized")
    elseif current ~= collected then
        print_debug(current, "detail", "\\ Corrected")
    end

    -- cycle last_seen
    for whxy, table_ in pairs(stats.trusted) do
        if whxy ~= current.whxy then
            if table_.time.last_seen > 0 then table_.time.last_seen = 0 end
            table_.time.last_seen = table_.time.last_seen - elapsed_time
        else
            if table_.time.last_seen < 0 then table_.time.last_seen = 0 end
            table_.time.last_seen = table_.time.last_seen + elapsed_time
        end
    end

    -- last check before add a new meta as trusted
    local new_ready = stats.buffer[collected.whxy] and
                          (collected.is_known_ratio and collected.time.buffer >= new_known_ratio_timer or fallback and
                              not collected.is_known_ratio and collected.time.buffer >= new_fallback_timer)
    local detect_source = current.is_source and
                              (current == collected and last_collected == current and limit.change == 1 or
                                  current.time.last_seen >= fast_change_timer)
    local confirmation = not current.is_source and
                             (stats.trusted[current.whxy] and current.time.last_seen >= fast_change_timer or new_ready)
    local crop_filter = not collected.is_invalid and applied.whxy ~= current.whxy and
                            is_trusted_offset(current.offset.x, "x") and is_trusted_offset(current.offset.y, "y") and
                            (confirmation or detect_source)
    -- apply crop
    if crop_filter then
        local already_stable
        if stats.trusted[current.whxy] then
            current.applied = current.applied + 1
        else
            -- add the metadata to the trusted list
            stats.trusted[current.whxy] = current
            current.applied, current.time.last_seen = 1, current.time.buffer
            current.is_trusted_offsets = true
            if check_stability(current) then already_stable, current.applied = true, 0 end
        end
        if not already_stable then
            if not time_pos.prevent or time_pos_ >= time_pos.prevent then
                osd_size_change(current.w > current.h)
                mp.command(string.format("no-osd vf append @%s:lavfi-crop=%s", labels.crop, current.whxy))
                print_debug(string.format("- Apply: %s", current.whxy))
                if prevent_change_timer > 0 then
                    time_pos.prevent = nil
                    if (options.prevent_change_mode == 1 and (current.w > applied.w or current.h > applied.h) or
                        options.prevent_change_mode == 2 and (current.w < applied.w or current.h < applied.h) or
                        options.prevent_change_mode == 0) then
                        time_pos.prevent = time_pos_ + prevent_change_timer
                    end
                end
            end
            applied = current
            if options.mode < 3 then on_toggle(true) end
        end
    end

    -- cleanup buffer
    while time_to_cleanup_buffer(buffer.time_known, new_known_ratio_timer) do
        local position = (buffer.index_total + 1) - buffer.index_known_ratio
        buffer.time_known = buffer.time_known - buffer.ordered[position][2]
        buffer.index_known_ratio = buffer.index_known_ratio - 1
    end
    local buffer_timer = new_fallback_timer
    if not fallback then buffer_timer = new_known_ratio_timer end
    local function proactive_cleanup() -- start to cleanup if too much unique meta are present
        return buffer.time_total > buffer.time_known and buffer.unique_meta > buffer.index_total *
                   (buffer_timer * options.segmentation / (buffer_timer * (1 + options.segmentation))) + 1
    end
    while time_to_cleanup_buffer(buffer.time_total, buffer_timer) or proactive_cleanup() do
        local ref = buffer.ordered[1][1]
        ref.time.buffer = ref.time.buffer - buffer.ordered[1][2]
        if stats.buffer[ref.whxy] and ref.time.buffer == 0 then
            stats.buffer[ref.whxy] = nil
            buffer.unique_meta = buffer.unique_meta - 1
        end
        buffer.time_total = buffer.time_total - buffer.ordered[1][2]
        buffer.index_total = buffer.index_total - 1
        table.remove(buffer.ordered, 1)
    end

    -- auto limit
    local b_adjust_limit = adjust_limit(current)
    last_collected = collected
    if b_adjust_limit then insert_cropdetect_filter() end
end

local function update_time_pos(_, time_pos_)
    -- time_pos_ is %.3f
    if not time_pos_ then return end

    time_pos.prev = time_pos.current
    time_pos.current = math.floor(time_pos_ * 1000)
    if not time_pos.insert then time_pos.insert = time_pos.current end

    if in_progress or not collected.whxy or not time_pos.prev or filter_inserted or seeking or paused or toggled or
        time_pos_ < options.start_delay then return end

    process_metadata("time_pos", time_pos.current)
    collectgarbage("step")
    in_progress = false
end

local function collect_metadata(_, table_)
    -- check the new metadata for availability and change
    if table_ and table_["lavfi.cropdetect.w"] and table_["lavfi.cropdetect.h"] then
        local tmp = {
            w = tonumber(table_["lavfi.cropdetect.w"]),
            h = tonumber(table_["lavfi.cropdetect.h"]),
            x = tonumber(table_["lavfi.cropdetect.x"]),
            y = tonumber(table_["lavfi.cropdetect.y"])
        }
        tmp.whxy = string.format("w=%s:h=%s:x=%s:y=%s", tmp.w, tmp.h, tmp.x, tmp.y)
        time_pos.insert = time_pos.current
        if tmp.whxy ~= collected.whxy then
            -- use known table if exists or compute meta
            if stats.trusted[tmp.whxy] then
                collected = stats.trusted[tmp.whxy]
            elseif stats.buffer[tmp.whxy] then
                collected = stats.buffer[tmp.whxy]
            else
                collected = compute_meta(tmp)
            end
        end
        filter_inserted = false
    end
end

local function seek(name, filter_change)
    print_debug(string.format("Stop by %s event.", name))
    if filter_change then remove_filter(labels.cropdetect) end
    time_pos, collected = {}, {}
end

local function resume(name, filter_change)
    print_debug(string.format("Resume by %s event.", name))
    if filter_change then insert_cropdetect_filter() end
end

local function playback_events(event, id, error)
    if event["event"] == "seek" then
        seeking = true
        if not paused then seek(event["event"], false) end
    else
        if not paused then resume(event["event"], false) end
        seeking = false
    end
end

function on_toggle(auto)
    if filter_missing then
        mp.osd_message("Libavfilter cropdetect missing", 3)
        return
    end
    if is_filter_present(labels.crop) and not is_filter_present(labels.cropdetect) then
        remove_filter(labels.crop)
        applied = source
        return
    end
    if not toggled then
        seek("toggle", true)
        if not auto then mp.osd_message(string.format("%s paused.", label_prefix), 3) end
        toggled = true
    else
        toggled = false
        resume("toggle", true)
        if not auto then mp.osd_message(string.format("%s resumed.", label_prefix), 3) end
    end
end

local function pause(_, bool)
    if bool then
        seek("pause", true)
        print_debug(nil, "stats")
        paused = true
    else
        paused = false
        if not toggled then resume("unpause", true) end
    end
end

function cleanup()
    if not paused then print_debug(nil, "stats") end
    mp.msg.info("Cleanup.")
    mp.unregister_event(playback_events)
    mp.unobserve_property(collect_metadata)
    mp.unobserve_property(update_time_pos)
    mp.unobserve_property(osd_size_change)
    mp.unobserve_property(pause)
    for _, label in pairs(labels) do remove_filter(label) end
end

local function on_start()
    mp.msg.info("File loaded.")
    if not is_cropable() then
        mp.msg.warn("Exit, only works for videos.")
        return
    end
    -- init/re-init source, buffer, limit and other data
    local w, h = mp.get_property_number("width"), mp.get_property_number("height")
    buffer = {ordered = {}, time_total = 0, time_known = 0, index_total = 0, index_known_ratio = 0, unique_meta = 0}
    limit = {current = options.detect_limit, step = 1, up = 2}
    collected, stats = {}, {trusted = {}, buffer = {}, trusted_offset = {x = {}, y = {}}}
    source = {
        w = math.floor(w / options.detect_round) * options.detect_round,
        h = math.floor(h / options.detect_round) * options.detect_round
    }
    source.x, source.y = (w - source.w) / 2, (h - source.h) / 2
    source = compute_meta(source)
    stats.trusted_offset = {x = {source.offset.x}, y = {source.offset.y}}
    source.applied, source.time.last_seen = 1, 0
    applied, stats.trusted[source.whxy] = source, source
    time_pos.current = mp.get_property_number("time-pos")
    -- register events
    mp.observe_property("osd-dimensions", "native", osd_size_change)
    mp.register_event("seek", playback_events)
    mp.register_event("playback-restart", playback_events)
    mp.observe_property("pause", "bool", pause)
    mp.observe_property(string.format("vf-metadata/%s", labels.cropdetect), "native", collect_metadata)
    mp.observe_property("time-pos", "number", update_time_pos)
    if options.mode % 2 == 1 then on_toggle(true) end
end

mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
