--[[
This script uses the lavfi cropdetect filter to automatically insert a crop filter with appropriate parameters for the
currently playing video, the script run continuously by default, base on the mode choosed.
It will automatically crop the video, when playback starts.

Also It registers the key-binding "C" (shift+c). You can manually crop the video by pressing the "C" (shift+c) key.
If the "C" key is pressed again, the crop filter is removed restoring playback to its original state.

The workflow is as follows: First, it inserts the filter vf=lavfi=cropdetect. After <detect_seconds> (default is < 1)
seconds, then w,h,x,y are gathered from the vf-metadata left by cropdetect.
The cropdetect filter is removed immediately after and finally it inserts the filter vf=lavfi=crop=w:h:x:y.

The default options can be overridden by adding script-opts-append=<script_name>-<parameter>=<value> into mpv.conf
    script-opts-append=dynamic_crop-mode=0
    script-opts-append=dynamic_crop-ratios=2.4 2.39 2 4/3 ("" aren't needed like below)

List of available parameters (For default values, see <options>)：

prevent_change_mode: [0-2] - 0 any, 1 keep-largest, 2 keep-lowest - The prevent_change_timer is trigger after a change,
    to disable this, set prevent_change_timer to 0.

resize_windowed: [true/false] - False, prevents the window from being resized, but always applies cropping,
    this function always avoids the default behavior to resize the window at the source size, in windowed/maximized mode.

deviation: % in float e.g. 0.5 for 50% - Extra time to allow new metadata to be segmented instead of being continuous.
    to disable this, set 0.

correction: [0.0-1] - Size minimum of collected meta (in percent based on source), to attempt a correction.
    to disable this, set 1.
]] --
require "mp.msg"
require "mp.options"

local options = {
    -- behavior
    mode = 4, -- [0-4] 0 disable, 1 on-demand, 2 single-start, 3 auto-manual, 4 auto-start.
    start_delay = 0, -- delay in seconds used to skip intro.
    prevent_change_timer = 0,
    prevent_change_mode = 2,
    resize_windowed = true,
    fast_change_timer = 1,
    new_known_ratio_timer = 5,
    new_fallback_timer = 20, -- 0 disable or >= 'new_known_ratio_timer'.
    ratios = "2.4 2.39 2.35 2.2 2 1.85 16/9 5/3 1.5 4/3 1.25 9/16", -- list separated by space.
    ratios_diff = 2, -- even number, pixel added to check the known ratio list.
    deviation = 0.5, -- %, 0 for approved only a continuous metadata.
    correction = 0.6, -- %, 0.6 equivalent to 60%. -- TODO auto value with trusted meta
    -- filter, see https://ffmpeg.org/ffmpeg-filters.html#cropdetect for details.
    detect_limit = 24,
    detect_round = 2, -- even number.
    detect_reset = 1, -- minimum 1.
    detect_skip = 1, -- minimum 1, default 2 (new ffmpeg build since 12/2020).
    -- verbose
    debug = false
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
local in_progress, seeking, paused, toggled, filter_missing, filter_inserted
-- Init on_start()
local applied, buffer, collected, last_collected, limit, source, stats
-- option
local time_pos = {}
local fallback = options.new_fallback_timer >= options.new_known_ratio_timer
local cropdetect_skip = string.format(":skip=%d", options.detect_skip)

local function is_trusted_offset(offset, axis)
    for _, v in pairs(stats.trusted_offset[axis]) do if offset == v then return true end end
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

local function remove_filter(label)
    if is_filter_present(label) then mp.command(string.format("no-osd vf remove @%s", label)) end
end

local function insert_cropdetect_filter()
    if toggled or paused or seeking then return end
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
    filter_inserted = true
end

local function compute_meta(meta)
    meta.whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y)
    meta.offset = {x = meta.x - (source.w - meta.w) / 2, y = meta.y - (source.h - meta.h) / 2}
    meta.mt, meta.mb = meta.y, source.h - meta.h - meta.y
    meta.ml, meta.mr = meta.x, source.w - meta.w - meta.x
    meta.is_source = meta.whxy == source.whxy or meta.w == source.rw and meta.h == source.rh and meta.offset.x == 0 and
                         meta.offset.y == 0
    meta.is_invalid = meta.h < 0 or meta.w < 0
    meta.detected_total = 0
    -- Check aspect ratio
    if not meta.is_invalid and meta.w >= source.w * .9 or meta.h >= source.h * .9 then
        for ratio in string.gmatch(options.ratios, "%S+%s?") do
            for a, b in string.gmatch(ratio, "(%d+)/(%d+)") do ratio = a / b end
            local height = math.floor((meta.w * 1 / ratio) + .5)
            if math.abs(height - meta.h) <= options.ratios_diff + 1 then
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

local function print_debug(meta, type_, label)
    if options.debug then
        if type_ == "detail" then
            print(string.format("%s, %s | Offset X:%s Y:%s | limit:%s", label, meta.whxy, meta.offset.x, meta.offset.y,
                                limit.current))
        end
        if not type_ then print(meta) end
    end
    -- Debug Stats
    if type_ == "stats" and stats.trusted then
        mp.msg.info("Meta Stats:")
        local read_maj_offset = {x = "", y = ""}
        for axis, _ in pairs(read_maj_offset) do
            for _, v in pairs(stats.trusted_offset[axis]) do
                read_maj_offset[axis] = read_maj_offset[axis] .. v .. " "
            end
        end
        mp.msg.info(string.format("Trusted Offset: X:%s Y:%s", read_maj_offset.x, read_maj_offset.y))
        for whxy, table_ in pairs(stats.trusted) do
            if stats.trusted[whxy] then
                mp.msg.info(string.format("%s | offX=%s offY=%s | applied=%s detected_total=%s last=%s", whxy,
                                          table_.offset.x, table_.offset.y, table_.applied, table_.detected_total,
                                          table_.last_seen))
            end
        end
        if options.debug then
            if stats.buffer then
                for whxy, table_ in pairs(stats.buffer) do
                    mp.msg.info(string.format("- %s | offX=%s offY=%s | detected_total=%s ratio=%s", whxy,
                                              table_.offset.x, table_.offset.y, table_.detected_total,
                                              table_.is_known_ratio))
                end
            end
            mp.msg.info("Buffer: T", buffer.time_total, buffer.index_total, "| count_diff:", buffer.count_diff, "| KR",
                        buffer.time_known, buffer.index_known_ratio)

            -- for k, ref in pairs(buffer.ordered) do
            --     if k == buffer.index_total - (buffer.index_known_ratio - 1) then
            --         print("-", k, ref[1], ref[1].whxy, ref[2], ref[3])
            --     else
            --         print(k, ref[1], ref[1].whxy, ref[2], ref[3])
            --     end
            -- end
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
    if meta.is_source then
        -- Increase limit
        limit.change = 1
        if limit.current + limit.step * limit.up <= options.detect_limit then
            limit.current = limit.current + limit.step * limit.up
        else
            limit.current = options.detect_limit
        end
    elseif not meta.is_invalid and (last_collected == collected or math.abs(collected.w - last_collected.w) <= 2 and
        math.abs(collected.h - last_collected.h) <= 2) then
        -- math.abs <= 2 are there to help stabilize odd metadata
        limit.change = 0
    else
        -- Decrease limit
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

local function compute_float(number_1, number_2, increase)
    if increase then
        return tonumber(string.format("%.3f", number_1 + number_2))
    else
        return tonumber(string.format("%.3f", number_1 - number_2))
    end
end

local function process_metadata(event, time_pos_)
    -- Prevent Event Race
    in_progress = true

    local elapsed_time = compute_float(time_pos_, time_pos.insert, false)
    print_debug(collected, "detail", "Collected")
    time_pos.insert = time_pos_

    -- Increase detected_total time
    collected.detected_total = compute_float(collected.detected_total, elapsed_time, true)

    -- Buffer cycle
    if buffer.index_total == 0 or buffer.ordered[buffer.index_total][1] ~= collected then
        table.insert(buffer.ordered, {collected, elapsed_time})
        buffer.index_total = buffer.index_total + 1
        buffer.index_known_ratio = buffer.index_known_ratio + 1
    elseif last_collected == collected then
        local i = buffer.index_total
        buffer.ordered[i][2] = compute_float(buffer.ordered[i][2], elapsed_time, true)
    end
    buffer.time_total = compute_float(buffer.time_total, elapsed_time, true)
    if buffer.index_known_ratio > 0 then buffer.time_known = compute_float(buffer.time_known, elapsed_time, true) end

    -- Check if a new meta can be approved
    local new_ready = stats.buffer[collected.whxy] and
                          (collected.is_known_ratio and collected.detected_total >= options.new_known_ratio_timer or
                              fallback and not collected.is_known_ratio and collected.detected_total >=
                              options.new_fallback_timer)

    -- Add Trusted Offset
    if new_ready then
        local add_new_offset = {}
        for _, axis in pairs({"x", "y"}) do
            add_new_offset[axis] = not collected.is_invalid and not is_trusted_offset(collected.offset[axis], axis)
            if add_new_offset[axis] then table.insert(stats.trusted_offset[axis], collected.offset[axis]) end
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
        -- Check if the corrected data is already applied
        if closest.whxy and not in_between and closest.whxy ~= applied.whxy then
            corrected = stats.trusted[closest.whxy]
        end
    end

    -- Use corrected metadata as main data
    local current = collected
    if corrected then current = corrected end

    -- Stabilization
    local stabilization
    if not current.is_source and stats.trusted[current.whxy] then
        for _, table_ in pairs(stats.trusted) do
            if current ~= table_ then
                if (not stabilization and table_.detected_total > current.detected_total or stabilization and
                    table_.detected_total > stabilization.detected_total) and math.abs(current.w - table_.w) <= 4 and
                    math.abs(current.h - table_.h) <= 4 then stabilization = table_ end
            end
        end
    end
    if stabilization then
        current = stabilization
        print_debug(current, "detail", "\\ Stabilized")
    elseif corrected then
        print_debug(current, "detail", "\\ Corrected")
    end

    -- Cycle last_seen
    for whxy, table_ in pairs(stats.trusted) do
        if whxy ~= current.whxy then
            if table_.last_seen > 0 then table_.last_seen = 0 end
            table_.last_seen = compute_float(table_.last_seen, elapsed_time, false)
        else
            if table_.last_seen < 0 then table_.last_seen = 0 end
            table_.last_seen = compute_float(table_.last_seen, elapsed_time, true)
        end
    end

    -- Crop Filter
    local detect_source = current.is_source and
                              (not corrected and last_collected == collected and limit.change == 1 or current.last_seen >=
                                  options.fast_change_timer)
    local trusted_offset_y = is_trusted_offset(current.offset.y, "y")
    local trusted_offset_x = is_trusted_offset(current.offset.x, "x")
    local confirmation = not current.is_source and
                             (stats.trusted[current.whxy] and current.last_seen >= options.fast_change_timer or
                                 new_ready)
    local crop_filter = not collected.is_invalid and applied.whxy ~= current.whxy and trusted_offset_x and
                            trusted_offset_y and (confirmation or detect_source)
    if crop_filter then
        -- Apply cropping
        if stats.trusted[current.whxy] then
            current.applied = current.applied + 1
        else
            stats.trusted[current.whxy] = current
            current.applied, current.last_seen = 1, current.detected_total
            stats.buffer[current.whxy] = nil
            buffer.count_diff = buffer.count_diff - 1
        end
        if not time_pos.prevent or time_pos_ >= time_pos.prevent then
            osd_size_change(current.w > current.h)
            mp.command(string.format("no-osd vf append @%s:lavfi-crop=%s", labels.crop, current.whxy))
            print_debug(string.format("- Apply: %s", current.whxy))
            if options.prevent_change_timer > 0 then
                time_pos.prevent = nil
                if (options.prevent_change_mode == 1 and (current.w > applied.w or current.h > applied.h) or
                    options.prevent_change_mode == 2 and (current.w < applied.w or current.h < applied.h) or
                    options.prevent_change_mode == 0) then
                    time_pos.prevent = compute_float(time_pos_, options.prevent_change_timer, true)
                end
            end
        end
        applied = current
        if options.mode < 3 then on_toggle(true) end
    end

    -- print("Buffer:", buffer.time_total, buffer.index_total, "|", buffer.count_diff, "|", buffer.time_known,
    --   buffer.index_known_ratio)
    while buffer.count_diff > buffer.fps_known_ratio and buffer.index_known_ratio > 24 or buffer.time_known >
        options.new_known_ratio_timer * (1 + options.deviation) do
        local position = (buffer.index_total + 1) - buffer.index_known_ratio
        local ref = buffer.ordered[position][1]
        local buffer_time = buffer.ordered[position][2]
        if stats.buffer[ref.whxy] and ref.is_known_ratio then
            ref.detected_total = compute_float(ref.detected_total, buffer_time, false)
            if ref.detected_total == 0 then
                stats.buffer[ref.whxy] = nil
                buffer.count_diff = buffer.count_diff - 1
            end
        end
        buffer.index_known_ratio = buffer.index_known_ratio - 1
        if buffer.index_known_ratio == 0 then
            buffer.time_known = 0
        else
            buffer.time_known = compute_float(buffer.time_known, buffer_time, false)
        end
    end

    local buffer_timer = options.new_fallback_timer
    if not fallback then buffer_timer = options.new_known_ratio_timer end
    while buffer.count_diff > buffer.fps_fallback and buffer.time_total > buffer.time_known or buffer.time_total >
        buffer_timer * (1 + options.deviation) do
        local ref = buffer.ordered[1][1]
        if stats.buffer[ref.whxy] and not ref.is_known_ratio then
            ref.detected_total = compute_float(ref.detected_total, buffer.ordered[1][2], false)
            if ref.detected_total == 0 then
                stats.buffer[ref.whxy] = nil
                buffer.count_diff = buffer.count_diff - 1
            end
        end
        buffer.time_total = compute_float(buffer.time_total, buffer.ordered[1][2], false)
        buffer.index_total = buffer.index_total - 1
        table.remove(buffer.ordered, 1)
    end
    -- print("Buffer:", buffer.time_total, buffer.index_total, "|", buffer.count_diff, "|", buffer.time_known, buffer.index_known_ratio)

    local b_adjust_limit = adjust_limit(current)
    last_collected = collected
    if b_adjust_limit then insert_cropdetect_filter() end
end

local function update_time_pos(_, time_pos_)
    if not time_pos_ then return end

    time_pos.prev = time_pos.current
    time_pos.current = tonumber(string.format("%.3f", time_pos_))
    if not time_pos.insert then time_pos.insert = time_pos.current end

    if in_progress or not collected.whxy or not time_pos.prev or filter_inserted or seeking or paused or toggled or
        time_pos_ < options.start_delay then return end

    process_metadata("time_pos", time_pos.current)
    collectgarbage("step")
    in_progress = false
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
        time_pos.insert = time_pos.current
        if tmp.whxy ~= collected.whxy then
            if stats.trusted[tmp.whxy] then
                collected = stats.trusted[tmp.whxy]
            elseif stats.buffer[tmp.whxy] then
                collected = stats.buffer[tmp.whxy]
            else
                collected = compute_meta(tmp)
            end
            -- Init stats.buffer[whxy]
            if not stats.trusted[collected.whxy] and not stats.buffer[collected.whxy] then
                stats.buffer[collected.whxy] = collected
                buffer.count_diff = buffer.count_diff + 1
            elseif stats.trusted[collected.whxy] and collected.last_seen < 0 then
                collected.last_seen = 0
            end
        end
        filter_inserted = false
    end
end

local function observe_main_event(observe)
    if observe then
        mp.observe_property(string.format("vf-metadata/%s", labels.cropdetect), "native", collect_metadata)
        mp.observe_property("time-pos", "number", update_time_pos)
        insert_cropdetect_filter()
    else
        mp.unobserve_property(update_time_pos)
        mp.unobserve_property(collect_metadata)
        remove_filter(labels.cropdetect)
    end
end

local function seek(name)
    print_debug(string.format("Stop by %s event.", name))
    observe_main_event(false)
    time_pos = {}
    collected = {}
end

local function resume(name)
    print_debug(string.format("Resume by %s event.", name))
    observe_main_event(true)
end

local function seek_event(event, id, error)
    seeking = true
    if not paused then
        print_debug(string.format("Stop by %s event.", event["event"]))
        time_pos = {}
        collected = {}
    end
end

local function resume_event(event, id, error)
    if not paused then print_debug(string.format("Resume by %s event.", event["event"])) end
    seeking = false
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
        seek("toggle")
        if not auto then mp.osd_message(string.format("%s paused.", label_prefix), 3) end
        toggled = true
    else
        toggled = false
        resume("toggle")
        if not auto then mp.osd_message(string.format("%s resumed.", label_prefix), 3) end
    end
end

local function pause(_, bool)
    if bool then
        seek("pause")
        print_debug(nil, "stats")
        paused = true
    else
        paused = false
        if not toggled then resume("unpause") end
    end
end

function cleanup()
    if not paused then print_debug(nil, "stats") end
    mp.msg.info("Cleanup.")
    -- Unregister Events
    observe_main_event(false)
    mp.unobserve_property(osd_size_change)
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
    buffer = {ordered = {}, time_total = 0, time_known = 0, index_total = 0, index_known_ratio = 0, count_diff = 0}
    limit = {current = options.detect_limit, step = 1, up = 2}
    collected, stats = {}, {trusted = {}, buffer = {}, trusted_offset = {x = {0}, y = {0}}}
    source = {
        w = math.floor(mp.get_property_number("width") / options.detect_round) * options.detect_round,
        h = math.floor(mp.get_property_number("height") / options.detect_round) * options.detect_round
    }
    source.x = (mp.get_property_number("width") - source.w) / 2
    source.y = (mp.get_property_number("height") - source.h) / 2
    source = compute_meta(source)
    source.applied, source.detected_total, source.last_seen = 1, 0, 0
    applied, stats.trusted[source.whxy] = source, source
    time_pos.current = mp.get_property_number("time-pos")
    if options.deviation == 0 then
        buffer.fps_known_ratio, buffer.fps_fallback = 2, 2
    else
        buffer.fps_known_ratio = math.ceil(options.new_known_ratio_timer * options.deviation /
                                               (1 / mp.get_property_number("container-fps")))
        buffer.fps_fallback = math.ceil(options.new_fallback_timer * options.deviation /
                                            (1 / mp.get_property_number("container-fps")))
    end
    -- limit.up = math.ceil(mp.get_property_number("video-params/average-bpp") / 6) -- slow load (arithmetic on nil value)
    -- Register Events
    mp.observe_property("osd-dimensions", "native", osd_size_change)
    mp.register_event("seek", seek_event)
    mp.register_event("playback-restart", resume_event)
    mp.observe_property("pause", "bool", pause)
    if options.mode % 2 == 1 then on_toggle(true) end
end

mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
