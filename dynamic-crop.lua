--[[
This script uses the lavfi cropdetect filter to automatically insert a crop filter with appropriate parameters for the
currently playing video, the script run continuously by default, base on the mode choosed.
It will automatically crop the video, when playback starts.

Also It registers the key-binding "C" (shift+c). You can manually crop the video by pressing the "C" (shift+c) key.
If the "C" key is pressed again, the crop filter is removed restoring playback to its original state.

The workflow is as follows: First, it inserts the filter vf=lavfi=cropdetect. After <detect_seconds> (default is < 1)
seconds, then w,h,x,y are gathered from the vf-metadata left by cropdetect.
The cropdetect filter is removed immediately after and finally it inserts the filter vf=lavfi=crop=w:h:x:y.

The default options can be overridden by adding script-opts-append=autocrop-<parameter>=<value> into mpv.conf

List of available parameters (For default values, see <options>)：

prevent_change_mode: [0-2] - 0 any, 1 keep-largest, 2 keep-lowest - The prevent_change_timer is trigger after a change,
    to disable this, set prevent_change_timer to 0.

resize_windowed: [true/false] - False, prevents the window from being resized, but always applies cropping,
    this function always avoids the default behavior to resize the window at the source size, in windowed/maximized mode.

deviation: seconds - Extra time may deviate from the majority collected to approve a new metadata (to validate: 6/6+2).
    to disable this, set 0.

correction: [0.0-1] - Size minimum of collected meta (in percent based on source), to attempt a correction.
    to disable this, set 1.
]] --
require "mp.msg"
require "mp.options"

local options = {
    -- behavior
    mode = 4, -- [0-4] 0 disable, 1 on-demand, 2 single-start, 3 auto-manual, 4 auto-start.
    start_delay = 0, -- Delay in seconds used to skip intro for mode 2 (single-start).
    prevent_change_timer = 0, -- TODO re implement
    prevent_change_mode = 2,
    resize_windowed = true,
    fast_change_timer = 1,
    new_known_ratio_timer = 6,
    new_fallback_timer = 0, -- 0 disable or >= 'new_known_ratio_timer'.
    ratios = {2.4, 2.39, 2.35, 2.2, 2, 1.85, 16 / 9, 1.5, 4 / 3, 1.25, 9 / 16},
    deviation = 1, -- 0 for approved only a continuous metadata.
    correction = 0.6, -- 0.6 equivalent to 60%.
    -- filter, see https://ffmpeg.org/ffmpeg-filters.html#cropdetect for details.
    detect_limit = 24,
    detect_round = 2,
    detect_reset = 1, -- minimum 1.
    detect_skip = 0, -- new ffmpeg build since 12/2020.
    -- verbose
    debug = true
}
read_options(options)

if options.mode == 0 then
    mp.msg.info("mode = 0, disable script.")
    return
end

-- Forward declaration
local cleanup, on_toggle
-- label
local label_prefix = mp.get_script_name()
local labels = {
    crop = string.format("%s-crop", label_prefix),
    cropdetect = string.format("%s-cropdetect", label_prefix)
}
-- state
local state = {}
local in_progress, seeking, paused, toggled, filter_missing, filter_removed
-- Init on_start()
local applied, buffer, collected, limit, source, stats, trusted_offset
-- option
local time_pos = {}
local fallback = options.new_fallback_timer >= options.new_known_ratio_timer
local cropdetect_skip = string.format(":skip=%d", options.detect_skip)

local function is_trusted_offset(offset, axis)
    for _, v in pairs(trusted_offset[axis]) do if offset == v then return true end end
    return false
end

local function is_filter_present(label)
    local filters = mp.get_property_native("vf")
    for _, filter in pairs(filters) do if filter["label"] == label then return true end end
    return false
end

local function is_cropable()
    local vid = mp.get_property_native("vid")
    local is_album = vid and mp.get_property_native(string.format("track-list/%s/albumart", vid)) or false
    return vid and not is_album
end

local function insert_cropdetect_filter()
    -- "vf pre" cropdetect / "vf append" crop, to be sure of the order of the chain filters
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
end

local function remove_filter(label)
    if is_filter_present(label) then mp.command(string.format("no-osd vf remove @%s", label)) end
end

local function compute_meta(meta)
    meta.whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y)
    meta.offset = {x = meta.x - (source.w - meta.w) / 2, y = meta.y - (source.h - meta.h) / 2}
    meta.mt, meta.mb = meta.y, source.h - meta.h - meta.y
    meta.ml, meta.mr = meta.x, source.w - meta.w - meta.x
    meta.is_source = meta.whxy == source.whxy or meta.w == source.rw and meta.h == source.rh and meta.offset.x == 0 and
                         meta.offset.y == 0
    meta.is_invalid = meta.h < 0 or meta.w < 0
    -- Check aspect ratio
    if not meta.is_invalid and meta.w >= source.w * .9 or meta.h >= source.h * .9 then
        for _, ratio in pairs(options.ratios) do
            local height = math.floor((meta.w * 1 / ratio) + .5)
            if height % 2 == 0 and height == meta.h or height % 2 == 1 and
                (height + 1 == meta.h or height - 1 == meta.h) then
                meta.known_ratio_detected = 0
                break
            end
        end
    end
    if not meta.known_ratio_detected and fallback then meta.fallback_detected = 0 end
    return meta
end

local function osd_size_change(orientation)
    local prop_maximized = mp.get_property("window-maximized")
    local prop_fullscreen = mp.get_property("fullscreen")
    local osd = mp.get_property_native("osd-dimensions")
    if prop_fullscreen == "no" then
        -- Keep window width or height to avoid reset to source size when cropping.
        -- print("osd-width:", osd.w, "osd-height:", osd.h, "margin:", osd.mt, osd.mb, osd.ml, osd.mr)
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

local function print_debug(type_, label, meta)
    if options.debug and type_ == "detail" then
        print(string.format("%s, %s | Offset X:%s Y:%s | limit:%s", label, meta.whxy, meta.offset.x, meta.offset.y,
                            limit.current))
    else
        -- type_ = nil
        print(type_)
    end
    -- Debug Stats
    if type_ == "stats" and stats.trusted then
        mp.msg.info("Meta Stats:")
        local read_maj_offset = {x = "", y = ""}
        for axis, _ in pairs(read_maj_offset) do
            for _, v in pairs(trusted_offset[axis]) do
                read_maj_offset[axis] = read_maj_offset[axis] .. v .. " "
            end
        end
        mp.msg.info(string.format("Trusted Offset: X:%s Y:%s", read_maj_offset.x, read_maj_offset.y))
        for whxy in pairs(stats.trusted) do
            if stats.trusted[whxy] then
                mp.msg.info(string.format("%s | offX=%s offY=%s | applied=%s detected=%s last=%s", whxy,
                                          stats.trusted[whxy].offset.x, stats.trusted[whxy].offset.y,
                                          stats.trusted[whxy].applied, stats.trusted[whxy].detected,
                                          stats.trusted[whxy].last_seen))
            end
        end
        if options.debug then
            if stats.buffer then
                for whxy in pairs(stats.buffer) do
                    mp.msg.info(string.format("- %s | offX=%s offY=%s | fallback=%s known_ratio=%s", whxy,
                                              stats.buffer[whxy].offset.x, stats.buffer[whxy].offset.y,
                                              stats.buffer[whxy].fallback_detected,
                                              stats.buffer[whxy].known_ratio_detected))
                end
            end
            mp.msg.info("Buffer:", buffer.time_total, buffer.index_total, "|", buffer.time_known,
                        buffer.index_known_ratio)
            for k, ref in pairs(buffer.ordered) do
                if k == buffer.index_total - (buffer.index_known_ratio - 1) then
                    print("-", k, ref[1], ref[1].whxy, ref[2])
                else
                    print(k, ref[1], ref[1].whxy, ref[2])
                end
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

local function auto_adjust_limit(meta)
    -- Auto adjust black threshold and detect_seconds
    limit.last = limit.change
    local limit_current = limit.current
    if meta.is_source then
        -- Increase limit
        limit.change = 1
        if limit.current + limit.step * 2 <= options.detect_limit then
            limit.current = limit.current + limit.step * 2
        else
            limit.current = options.detect_limit
        end
    else
        limit.change = -1
        local trusted_margin
        for whxy, table_ in pairs(stats.trusted) do
            if stats.trusted[whxy] then
                local diff = is_trusted_margin(whxy)
                if diff.count >= 2 then trusted_margin = true end
            end
        end
        local low_collected = meta.w < source.w * options.correction or meta.h < source.h * options.correction
        if limit.current > 0 and (not trusted_margin or low_collected) then
            -- Decrease limit
            if limit.current - limit.step >= 0 then
                limit.current = limit.current - limit.step
            else
                limit.current = 0
            end
        end
    end

    if limit_current ~= limit.current then insert_cropdetect_filter() end
end

local function process_metadata(event)
    -- Prevent Event Race
    in_progress = true

    if seeking or paused or toggled then
        in_progress = false
        return
    end

    -- Time elapsed
    local time = time_pos.prev
    if event then time = time_pos.current end

    local elapsed_time = string.format("%.3f", time - time_pos.insert)
    print("Playback time:", elapsed_time, collected.whxy, limit.current, event)
    time_pos.insert = time
    -- print_debug("detail", "Collected", collected)

    -- Increase detected time
    if stats.trusted[collected.whxy] then
        collected.detected = string.format("%.3f", collected.detected) + elapsed_time
    else
        if collected.known_ratio_detected then
            collected.known_ratio_detected = string.format("%.3f", collected.known_ratio_detected) + elapsed_time
        elseif fallback then
            collected.fallback_detected = string.format("%.3f", collected.fallback_detected) + elapsed_time
        end
    end

    -- Buffer cycle
    table.insert(buffer.ordered, {collected, elapsed_time})
    buffer.time_total = string.format("%.3f", buffer.time_total) + elapsed_time
    buffer.time_known = string.format("%.3f", buffer.time_known) + elapsed_time
    buffer.index_total = buffer.index_total + 1
    buffer.index_known_ratio = buffer.index_known_ratio + 1
    -- TODO if more than x different value
    while buffer.time_known > options.new_known_ratio_timer + options.deviation do
        local position = (buffer.index_total + 1) - buffer.index_known_ratio
        local ref = buffer.ordered[position][1]
        local buffer_time = buffer.ordered[position][2]
        buffer.time_known = string.format("%.3f", buffer.time_known) - buffer_time
        if stats.buffer[ref.whxy] and ref.known_ratio_detected then
            ref.known_ratio_detected = string.format("%.3f", ref.known_ratio_detected) - buffer_time
            if ref.known_ratio_detected == 0 then stats.buffer[ref.whxy] = nil end
        end
        buffer.index_known_ratio = buffer.index_known_ratio - 1
    end

    local buffer_timer = options.new_fallback_timer
    if not fallback then buffer_timer = options.new_known_ratio_timer end
    while buffer.time_total > buffer_timer + options.deviation do
        local ref = buffer.ordered[1][1]
        if stats.buffer[ref.whxy] and ref.fallback_detected then
            ref.fallback_detected = string.format("%.3f", ref.fallback_detected) - buffer.ordered[1][2]
            if ref.fallback_detected == 0 then stats.buffer[ref.whxy] = nil end
        end
        buffer.time_total = string.format("%.3f", buffer.time_total) - buffer.ordered[1][2]
        buffer.index_total = buffer.index_total - 1
        table.remove(buffer.ordered, 1)
    end
    -- print("Buffer:", buffer.time_total, buffer.index_total, "|", buffer.time_known, buffer.index_known_ratio)

    -- Check if a new meta can be approved
    local new_ready = stats.buffer[collected.whxy] and
                          (collected.known_ratio_detected and collected.known_ratio_detected >=
                              options.new_known_ratio_timer or collected.fallback_detected and fallback and
                              collected.fallback_detected >= options.new_fallback_timer)

    -- Add Trusted Offset
    if new_ready then
        local add_new_offset = {}
        for _, axis in pairs({"x", "y"}) do
            add_new_offset[axis] = not collected.is_invalid and not is_trusted_offset(collected.offset[axis], axis)
            if add_new_offset[axis] then table.insert(trusted_offset[axis], collected.offset[axis]) end
        end
    end

    -- Meta correction
    local corrected
    if not collected.is_invalid and not stats.trusted[collected.whxy] and
        (collected.w > source.w * options.correction and collected.h > source.h * options.correction) then
        -- Find closest meta already applied
        local closest, in_between = {}, false
        for whxy in pairs(stats.trusted) do
            local diff = is_trusted_margin(whxy)
            -- print_debug(string.format("\\ Search %s, %s %s %s %s, %s", whxy, diff.mt, diff.mb, diff.ml, diff.mr,
            --   diff.count))
            -- Check if we have the same position between two set of margin
            if closest.whxy and closest.whxy ~= whxy and diff.count == closest.count and math.abs(diff.mt - diff.mb) ==
                math.abs(closest.mt - closest.mb) and math.abs(diff.ml - diff.mr) == math.abs(closest.ml - closest.mr) then
                in_between = true
                -- print_debug(string.format("\\ Cancel %s, in between.", closest.whxy))
                break
            end
            if not closest.whxy and diff.count >= 2 or closest.whxy and diff.count >= closest.count and diff.mt +
                diff.mb <= closest.mt + closest.mb and diff.ml + diff.mr <= closest.ml + closest.mr then
                closest.mt, closest.mb, closest.ml, closest.mr = diff.mt, diff.mb, diff.ml, diff.mr
                closest.count, closest.whxy = diff.count, whxy
                -- print_debug(string.format("  \\ Find %s", closest.whxy))
            end
        end
        -- Check if the corrected data is already applied or flush it
        if closest.whxy and not in_between and closest.whxy ~= applied.whxy then
            corrected = stats.trusted[closest.whxy]
        end
    end

    -- Use corrected metadata as main data
    local current = collected
    if corrected then
        print_debug("detail", "\\ Corrected", corrected)
        current = corrected
    end

    -- Stabilization
    local stabilization
    if not current.is_source and stats.trusted[current.whxy] then
        for _, table_ in pairs(stats.trusted) do
            if current ~= table_ then
                if (not stabilization and table_.detected > current.detected or stabilization and table_.detected >
                    stabilization.detected) and math.abs(current.w - table_.w) <= 4 and math.abs(current.h - table_.h) <=
                    4 then stabilization = table_ end
            end
        end
    end
    if stabilization then current = stabilization end

    -- Cycle last_seen
    for whxy in pairs(stats.trusted) do
        if whxy ~= current.whxy then
            if stats.trusted[whxy].last_seen > 0 then stats.trusted[whxy].last_seen = 0 end
            stats.trusted[whxy].last_seen = string.format("%.3f", stats.trusted[whxy].last_seen) - elapsed_time
        else
            if stats.trusted[whxy].last_seen < 0 then stats.trusted[whxy].last_seen = 0 end
            stats.trusted[whxy].last_seen = string.format("%.3f", stats.trusted[whxy].last_seen) + elapsed_time
        end
    end

    local detect_source = current.is_source and
                              (not corrected and limit.last == 1 or stats.trusted[current.whxy].last_seen >=
                                  options.fast_change_timer)
    local trusted_offset_y = is_trusted_offset(current.offset.y, "y")
    local trusted_offset_x = is_trusted_offset(current.offset.x, "x")

    -- Crop Filter
    local confirmation = not current.is_source and
                             (stats.trusted[current.whxy] and stats.trusted[current.whxy].last_seen >=
                                 options.fast_change_timer or new_ready)
    local crop_filter = not collected.is_invalid and applied.whxy ~= current.whxy and trusted_offset_x and
                            trusted_offset_y and (confirmation or detect_source)

    if crop_filter then
        -- Apply cropping
        if stats.trusted[current.whxy] then
            stats.trusted[current.whxy].applied = stats.trusted[current.whxy].applied + 1
        else
            stats.trusted[current.whxy] = current
            current.applied = 1
            current.detected = current.known_ratio_detected or current.fallback_detected
            current.last_seen = current.known_ratio_detected or current.fallback_detected
            current.fallback_detected, current.known_ratio_detected = nil, nil
            stats.buffer[current.whxy] = nil
        end
        osd_size_change(current.w > current.h)
        mp.command(string.format("no-osd vf append @%s:lavfi-crop=%s", labels.crop, current.whxy))
        print_debug(string.format("- Apply: %s", current.whxy))
        applied = current
        if options.mode < 3 then on_toggle(true) end
    end

    if corrected and corrected.is_source then auto_adjust_limit(corrected) end
    in_progress = false
end

local function update_time_pos(_, time)
    if not time or in_progress or not collected.whxy then return end

    time_pos.prev = time_pos.current
    time_pos.current = time
    if not time_pos.insert then time_pos.insert = time end

    if collected.is_source and time_pos.current > time_pos.insert and collected ~= applied then
        process_metadata("source")
        auto_adjust_limit(collected)
    elseif state.pull and stats.trusted[collected.whxy] and collected.last_seen >= 0 and time_pos.current >=
        time_pos.insert + (options.fast_change_timer - collected.last_seen) and applied.whxy ~= collected.whxy then
        state.pull = false
        process_metadata("fast change")
    elseif state.pull and stats.buffer[collected.whxy] and collected.known_ratio_detected and time_pos.current >=
        time_pos.insert + (options.new_known_ratio_timer - collected.known_ratio_detected) then
        state.pull = false
        process_metadata("know detected")
    elseif fallback and state.pull and stats.buffer[collected.whxy] and collected.fallback_detected and time_pos.current >=
        time_pos.insert + (options.new_fallback_timer - collected.fallback_detected) then
        state.pull = false
        process_metadata("fallback detected")
    elseif state.buffer_cycle and fallback and time_pos.current >=
        (time_pos.insert + options.new_fallback_timer + options.deviation) then
        state.buffer_cycle = false
        stats.buffer = {}
        buffer = {ordered = {}, time_total = 0, time_known = 0, index_total = 0, index_known_ratio = 0}
        process_metadata("cycle buffer")
    end
    -- Reset limit
    if (not state.pull or not state.buffer_cycle) and limit.current < options.detect_limit then
        limit.current = options.detect_limit
        insert_cropdetect_filter()
    end
end

local function collect_metadata(_, table_)
    -- Check the new metadata for availability and change
    if table_ and table_["lavfi.cropdetect.w"] and table_["lavfi.cropdetect.h"] then
        local tmp = {
            w = tonumber(table_["lavfi.cropdetect.w"]),
            h = tonumber(table_["lavfi.cropdetect.h"]),
            x = tonumber(table_["lavfi.cropdetect.x"]),
            y = tonumber(table_["lavfi.cropdetect.y"])
        }
        tmp.whxy = string.format("w=%s:h=%s:x=%s:y=%s", tmp.w, tmp.h, tmp.x, tmp.y)
        if tmp.whxy ~= collected.whxy then
            state.pull = true
            state.buffer_cycle = true
            if collected.whxy and time_pos.prev and time_pos.prev > time_pos.insert then process_metadata() end
            if stats.trusted[tmp.whxy] then
                collected = stats.trusted[tmp.whxy]
            elseif stats.buffer[tmp.whxy] then
                collected = stats.buffer[tmp.whxy]
            else
                collected = compute_meta(tmp)
            end
            -- Init stats.buffer[whxy]
            if not stats.trusted[collected.whxy] and not stats.buffer[collected.whxy] and
                (collected.known_ratio_detected or collected.fallback_detected) then
                stats.buffer[collected.whxy] = collected
            elseif stats.trusted[collected.whxy] and collected.last_seen < 0 then
                collected.last_seen = 0
            end
            auto_adjust_limit(collected)
        end
    else
        -- TODO improve reset
        -- Reset after inserting filter (table_.x=nil)
        if collected.whxy and time_pos.current and time_pos.current > time_pos.insert then
            state.pull = true
            process_metadata("reset")
        end
        time_pos.insert = time_pos.current
        collected = {}
    end
end

local function seek(name)
    print_debug(string.format("Stop by %s event.", name))
    remove_filter(labels.cropdetect)
    time_pos = {}
    collected = {}
end

local function resume(name)
    print_debug(string.format("Resume by %s event.", name))
    insert_cropdetect_filter()
end

local function seek_event(event, id, error)
    print_debug(string.format("Stop by %s event.", event["event"]))
    if not paused then
        time_pos = {}
        collected = {}
    end
    seeking = true
end

local function resume_event(event, id, error)
    print_debug(string.format("Resume by %s event.", event["event"]))
    seeking = false
end

function on_toggle(mode)
    if filter_missing then
        mp.osd_message("Libavfilter cropdetect missing", 3)
        return
    end
    if is_filter_present(labels.crop) and (filter_removed or options.mode >= 3) then
        remove_filter(labels.crop)
        remove_filter(labels.cropdetect)
        applied = source
        if options.mode <= 2 then
            filter_removed = false
            return
        end
    end
    if not toggled then
        toggled = true
        if not paused then seek("toggle") end
        mp.osd_message(string.format("%s paused.", label_prefix), 3)
    else
        toggled = false
        if not paused then resume("toggle") end
        mp.osd_message(string.format("%s resumed.", label_prefix), 3)
    end
    if mode then filter_removed = true end
end

local function pause(_, bool)
    if bool then
        paused = true
        seek("pause")
        print_debug("stats")
    else
        paused = false
        if not toggled then resume("unpause") end
    end
end

function cleanup()
    if not paused then print_debug("stats") end
    mp.msg.info("Cleanup.")
    -- Unregister Events
    mp.unobserve_property(osd_size_change)
    mp.unobserve_property(update_time_pos)
    mp.unobserve_property(collect_metadata)
    mp.unregister_event(seek_event)
    mp.unregister_event(resume_event)
    mp.unobserve_property(pause)
    -- Remove existing filters
    for _, label in pairs(labels) do remove_filter(label) end
end

local function on_start()
    mp.msg.info("File loaded.")
    if not is_cropable() then
        mp.msg.warn("Exit, only works for videos.")
        return
    end
    -- Init buffer, source, applied, stats.trusted
    buffer = {ordered = {}, time_total = 0, time_known = 0, index_total = 0, index_known_ratio = 0}
    limit = {current = options.detect_limit, step = 1}
    collected, stats = {}, {trusted = {}, buffer = {}}
    trusted_offset = {x = {0}, y = {0}}
    source = {
        w = math.floor(mp.get_property_number("width") / options.detect_round) * options.detect_round,
        h = math.floor(mp.get_property_number("height") / options.detect_round) * options.detect_round
    }
    source.x = (mp.get_property_number("width") - source.w) / 2
    source.y = (mp.get_property_number("height") - source.h) / 2
    source = compute_meta(source)
    source.applied, source.detected, source.last_seen = 1, 0, 0
    stats.trusted[source.whxy] = source
    applied = source
    time_pos.current = mp.get_property_number("time-pos")
    -- Register Events
    mp.observe_property("osd-dimensions", "native", osd_size_change)
    mp.observe_property("time-pos", "number", update_time_pos)
    mp.observe_property(string.format("vf-metadata/%s", labels.cropdetect), "native", collect_metadata)
    mp.register_event("seek", seek_event)
    mp.register_event("playback-restart", resume_event)
    mp.observe_property("pause", "bool", pause)
end

mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
