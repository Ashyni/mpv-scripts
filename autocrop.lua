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

mode: [0-4] - 0 disable, 1 on-demand, 2 single-start, 3 auto-manual, 4 auto-start

start_delay: seconds - Delay use by mode = 2 (single-start), to skip intro.

prevent_change_mode: [0-2] 0 any, 1 keep-largest, 2 keep-lowest - The prevent_change_timer is trigger after a change,
    set prevent_change_timer to 0, to disable this.

detect_limit, detect_round, detect_seconds: See https://ffmpeg.org/ffmpeg-filters.html#cropdetect
    other option for this filter: skip (new 12/2020), reset
]]
require "mp.msg"
require "mp.options"

local options = {
    -- behavior
    mode = 4,
    start_delay = 0,
    prevent_change_timer = 0,
    prevent_change_mode = 2,
    resize_windowed = true,
    fast_change_timer = 2,
    new_valid_ratio_timer = 6,
    new_fallback_timer = 18,
    ratios = {2.39, 2.35, 2.2, 2, 1.85, 16 / 9, 4 / 3, 9 / 16},
    -- ffmpeg-filter
    detect_limit = 24,
    detect_round = 2,
    detect_seconds = 0.45,
    detect_reset = 1,
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
local timers = {}
local in_progress, paused, toggled, seeking, filter_missing, clean_filter
-- metadata
local source, applied, stats, trusted_offset, collected, limit = {}, {}, {}, {}, {}, {}
local units = {"w", "h", "x", "y"}
-- option
local detect_seconds = options.detect_seconds
local new_fallback_timer = math.ceil(options.new_fallback_timer / (detect_seconds + .05))
local new_valid_ratio_timer = math.ceil(options.new_valid_ratio_timer / (detect_seconds + .05))
local fast_change_timer = math.ceil(options.fast_change_timer / (detect_seconds + .05))
limit.current = options.detect_limit
limit.last = options.detect_limit
limit.step = 2

local function is_trusted_offset(offset, axis)
    for _, v in pairs(trusted_offset[axis]) do
        if offset == v then
            return true
        end
    end
    return false
end

local function copy_meta(from, to)
    for _, unit in pairs(units) do
        to[unit] = from[unit]
    end
end

local function is_filter_present(label)
    local filters = mp.get_property_native("vf")
    for _, filter in pairs(filters) do
        if filter["label"] == label then
            return true
        end
    end
    return false
end

local function is_cropable()
    local vid = mp.get_property_native("vid")
    local is_album = vid and mp.get_property_native(string.format("track-list/%s/albumart", vid)) or false
    return vid and not is_album
end

local function insert_crop_filter()
    if not is_filter_present(labels.cropdetect) then
        -- "vf pre" cropdetect / "vf append" crop, to be sure of the order of the chain filters
        local insert_crop_filter_command =
            mp.command(
            string.format(
                "no-osd vf pre @%s:lavfi-cropdetect=limit=%.3f/255:round=%d:reset=%d",
                labels.cropdetect,
                limit.current,
                options.detect_round,
                options.detect_reset
            )
        )
        if not insert_crop_filter_command then
            mp.msg.error("Does vf=help as #1 line in mvp.conf return libavfilter list with crop/cropdetect in log?")
            filter_missing = true
            cleanup()
            return false
        end
    end
    return true
end

local function remove_filter(label)
    if is_filter_present(label) then
        mp.command(string.format("no-osd vf remove @%s", label))
    end
end

local function compute_meta(meta)
    meta.whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y)
    meta.detect_source = meta.whxy == source.whxy
    meta.already_apply = meta.whxy == applied.whxy
    meta.offset = {x = meta.x - (source.w - meta.w) / 2, y = meta.y - (source.h - meta.h) / 2}
    meta.mt = meta.y
    meta.mb = source.h - meta.h - meta.y
    meta.ml = meta.x
    meta.mr = source.w - meta.w - meta.x
end

local function osd_size_change()
    local prop_maximized = mp.get_property("window-maximized")
    local prop_fullscreen = mp.get_property("fullscreen")
    local osd = mp.get_property_native("osd-dimensions")
    if prop_fullscreen == "no" then
        -- Keep window width to avoid reset to source size when cropping.
        local w_r = tonumber(osd.w) - (tonumber(osd.ml) + tonumber(osd.mr))
        -- print("osd-width: ", osd.w, "osd-height: ", osd.h, "margin: ", osd.mt, osd.mb, osd.ml, osd.mr)
        if prop_maximized == "no" then
            if options.resize_windowed then
                mp.set_property("geometry", string.format("%s", w_r))
                mp.set_property("autofit", string.format("%s", w_r))
            else
                mp.set_property("geometry", string.format("%sx%s", osd.w, osd.h))
            end
        end
    end
end

local function print_debug(type, label, meta)
    if options.debug then
        if type == "detail" then
            print(
                string.format(
                    "%s, %s | mt:%s mb:%s ml:%s mr:%s | Offset X:%s Y:%s | limit:%s step:%s change:%s",
                    label,
                    meta.whxy,
                    meta.mt,
                    meta.mb,
                    meta.ml,
                    meta.mr,
                    meta.offset.x,
                    meta.offset.y,
                    limit.current,
                    limit.step,
                    limit.change
                )
            )
        else
            print(type)
        end
    end
    if type == "stats" then
        -- Debug Stats
        if stats[source.whxy] then
            mp.msg.info("Meta Stats:")
            local read_maj_offset = {x = "", y = ""}
            for axis, _ in pairs(read_maj_offset) do
                for _, v in pairs(trusted_offset[axis]) do
                    read_maj_offset[axis] = read_maj_offset[axis] .. v .. " "
                end
            end
            mp.msg.info(string.format("Trusted Offset: X:%s Y:%s", read_maj_offset.x, read_maj_offset.y))
            for whxy in pairs(stats) do
                mp.msg.info(
                    string.format(
                        "%s | offX=%s offY=%s | applied=%s detect=%s last_seen=%s potential=%s",
                        whxy,
                        stats[whxy].offset.x,
                        stats[whxy].offset.y,
                        stats[whxy].counter.applied,
                        stats[whxy].counter.detect,
                        stats[whxy].counter.last_seen,
                        stats[whxy].counter.potential
                    )
                )
            end
        end
    end
end

local function collect_metadata()
    local cropdetect_metadata = mp.get_property_native(string.format("vf-metadata/%s", labels.cropdetect))
    if cropdetect_metadata and cropdetect_metadata["lavfi.cropdetect.w"] then
        -- Remove filter to clear vf-metadata
        remove_filter(labels.cropdetect)
        -- Make metadata usable
        collected = {
            w = tonumber(cropdetect_metadata["lavfi.cropdetect.w"]),
            h = tonumber(cropdetect_metadata["lavfi.cropdetect.h"]),
            x = tonumber(cropdetect_metadata["lavfi.cropdetect.x"]),
            y = tonumber(cropdetect_metadata["lavfi.cropdetect.y"])
        }
        return true
    end
    if paused or toggled or seeking then
        remove_filter(labels.cropdetect)
    else
        detect_seconds = 0.025
    end
    return false
end

local function process_metadata()
    compute_meta(collected)
    print_debug("detail", "Collected", collected)
    local invalid = not (collected.h > 0 and collected.w > 0)
    local is_valid_ratio
    -- Store cropping meta, find trusted offset, and correct to closest meta if neccessary
    if not (collected.detect_source and limit.change == -1) then
        -- Store stats[whxy]
        if not stats[collected.whxy] then
            stats[collected.whxy] = {counter = {applied = 0, detect = 0, last_seen = 0, potential = 0}}
            copy_meta(collected, stats[collected.whxy])
            compute_meta(stats[collected.whxy])
        end
        stats[collected.whxy].counter.detect = stats[collected.whxy].counter.detect + 1
        -- Cycle potential
        stats[collected.whxy].counter.potential = stats[collected.whxy].counter.potential + 1
        if stats[collected.whxy].counter.applied > 0 then
            stats[collected.whxy].counter.potential = 0
        end
        for whxy in pairs(stats) do
            if whxy ~= collected.whxy and stats[whxy].counter.potential then
                if stats[whxy].counter.potential > 0 then
                    stats[whxy].counter.potential = 0
                end
            end
        end

        -- Check aspect ratio
        for _, ratio in pairs(options.ratios) do
            if collected.h == math.floor(collected.w / ratio) or collected.h == math.ceil(collected.w / ratio) then
                is_valid_ratio = true
            end
        end

        -- Add Trusted Offset
        local add_new_offset = {}
        for _, axis in pairs({"x", "y"}) do
            add_new_offset[axis] =
                not invalid and not is_trusted_offset(collected.offset[axis], axis) and
                (stats[collected.whxy].counter.potential > new_valid_ratio_timer and is_valid_ratio or
                    stats[collected.whxy].counter.potential > new_fallback_timer)
            if add_new_offset[axis] then
                table.insert(trusted_offset[axis], stats[collected.whxy].offset[axis])
            end
        end

        -- Meta correction
        if
            not invalid and stats[collected.whxy].counter.applied == 0 and
                (collected.w > source.w * 0.6 or collected.h > source.h * 0.6)
         then
            collected.corrected = {}
            -- Find closest margin already trusted
            local closest = {}
            for whxy in pairs(stats) do
                local diff = {}
                for _, margin in pairs({"mt", "mb", "ml", "mr"}) do
                    diff[margin] =
                        math.max(collected[margin], stats[whxy][margin]) -
                        math.min(collected[margin], stats[whxy][margin])
                end
                --print_debug(string.format("\\ Search %s | %s %s %s %s", whxy, diff.mt, diff.mb, diff.ml, diff.mr))
                if
                    stats[whxy].counter.applied > 0 and
                        (not closest.whxy or
                            diff.mt <= closest.mt and diff.mb <= closest.mb and diff.ml <= closest.ml and
                                diff.mr <= closest.mr)
                 then
                    closest.mt, closest.mb, closest.ml, closest.mr = diff.mt, diff.mb, diff.ml, diff.mr
                    closest.whxy = whxy
                --print_debug(string.format("\\ Find %s", closest.whxy))
                end
            end
            -- Check if the corrected data is already applied or flush it
            if closest.whxy ~= applied.whxy then
                copy_meta(collected, collected.corrected)
                collected.corrected.w, collected.corrected.h = stats[closest.whxy].w, stats[closest.whxy].h
                collected.corrected.x, collected.corrected.y = stats[closest.whxy].x, stats[closest.whxy].y
                compute_meta(collected.corrected)
            else
                collected.corrected = nil
            end
        end
    end

    -- Use corrected metadata as main data
    local current = collected
    if current.corrected then
        print_debug("detail", "\\ Corrected", collected.corrected)
        current = collected.corrected
    end

    -- Cycle last_seen
    for whxy in pairs(stats) do
        if whxy ~= current.whxy then
            if stats[whxy].counter.last_seen > 0 then
                stats[whxy].counter.last_seen = 0
            end
            stats[whxy].counter.last_seen = stats[whxy].counter.last_seen - 1
        else
            if stats[whxy].counter.last_seen < 0 then
                stats[whxy].counter.last_seen = 0
            end
            stats[whxy].counter.last_seen = stats[whxy].counter.last_seen + 1
        end
    end

    local detect_source =
        current.detect_source and (limit.change == 1 or stats[current.whxy].counter.last_seen > fast_change_timer)
    local trusted_offset_y = is_trusted_offset(current.offset.y, "y")
    local trusted_offset_x = is_trusted_offset(current.offset.x, "x")

    -- Auto adjust black threshold and detect_seconds
    limit.last = limit.current
    if current.detect_source then
        -- Increase limit
        limit.change = 1
        if limit.current < options.detect_limit then
            detect_seconds = .1
            if limit.current + limit.step * 2 <= options.detect_limit then
                limit.current = limit.current + limit.step * 2
                if stats[current.whxy].counter.last_seen > 2 then
                    limit.step = 2
                elseif limit.step >= .25 then
                    limit.step = limit.step / 2
                end
            else
                limit.current = options.detect_limit
            end
        end
    elseif
        not invalid and
            (collected.corrected and stats[collected.whxy].counter.potential > 1 or
                not collected.corrected and (trusted_offset_y or trusted_offset_x))
     then
        -- Stable data, reset limit/step
        limit.change, limit.step, detect_seconds = 0, 2, options.detect_seconds
        -- Allow detection of a second brighter crop
        local timer_reset = new_fallback_timer + 1
        if stats[current.whxy].counter.applied > 0 then
            timer_reset = fast_change_timer + 1
        elseif trusted_offset_y and trusted_offset_x then
            timer_reset = new_valid_ratio_timer + 1
        end
        if stats[current.whxy].counter.last_seen > timer_reset then
            limit.current = options.detect_limit
        else
            limit.current = math.ceil(limit.current)
        end
    elseif limit.current > 0 then
        -- Decrease limit
        limit.change, detect_seconds = -1, .1
        if limit.current - limit.step >= 0 then
            limit.current = limit.current - limit.step
        else
            limit.current = 0
        end
    end

    -- Crop Filter
    local confirmation =
        not current.detect_source and
        (stats[current.whxy].counter.applied > 0 and stats[current.whxy].counter.last_seen > fast_change_timer or
            stats[current.whxy].counter.last_seen > new_valid_ratio_timer and is_valid_ratio or
            stats[current.whxy].counter.last_seen > new_fallback_timer)
    local crop_filter =
        not invalid and not current.already_apply and trusted_offset_x and trusted_offset_y and
        (confirmation or detect_source)
    if crop_filter then
        -- Apply cropping
        stats[current.whxy].counter.applied = stats[current.whxy].counter.applied + 1
        if not timers.prevent_change or not timers.prevent_change:is_enabled() then
            mp.command(string.format("no-osd vf append @%s:lavfi-crop=%s", labels.crop, current.whxy))
            print_debug(string.format("- Apply: %s", current.whxy))
            -- Prevent upcomming change if a timers is defined
            if
                options.prevent_change_timer > 0 and
                    (options.prevent_change_mode == 1 and (current.w > applied.w or current.h > applied.h) or
                        options.prevent_change_mode == 2 and (current.w < applied.w or current.h < applied.h) or
                        options.prevent_change_mode == 0)
             then
                timers.prevent_change =
                    mp.add_timeout(
                    options.prevent_change_timer,
                    function()
                    end
                )
            end
            copy_meta(current, applied)
            compute_meta(applied)
        end
        if options.mode < 3 then
            on_toggle(true)
        end
    end

    -- Cleanup Stats
    for whxy in pairs(stats) do
        local stat_minority =
            stats[whxy].counter.last_seen < 0 and stats[whxy].counter.applied < 1 and stats[whxy].counter.potential == 0
        if stat_minority then
            -- Remove unwanted offset, if any, except 0
            for i_x, offset_x in pairs(trusted_offset.x) do
                if stats[whxy].offset.x == offset_x and stats[whxy].offset.x ~= 0 then
                    table.remove(trusted_offset.x, i_x)
                    break
                end
            end
            for i_y, offset_y in pairs(trusted_offset.y) do
                if stats[whxy].offset.y == offset_y and stats[whxy].offset.y ~= 0 then
                    table.remove(trusted_offset.y, i_y)
                    break
                end
            end
            -- Remove small detect, that was never applied
            stats[whxy] = nil
        end
    end
    collected = {}
end

local function auto_crop()
    -- Pause timers
    in_progress = true
    if timers.periodic_timer then
        timers.periodic_timer:stop()
    end

    -- Mode 1/3
    if options.mode % 2 == 1 and toggled == nil then
        toggled = true
        in_progress = false
        return
    end

    if not insert_crop_filter() then
        return
    end

    local time_needed = detect_seconds
    -- Wait to gather data
    timers.crop_detect =
        mp.add_timeout(
        time_needed,
        function()
            if collect_metadata() and not (paused or toggled or seeking) then
                process_metadata()
            end
            -- Resume timers
            in_progress = false
            if timers.periodic_timer and not paused and not toggled then
                timers.periodic_timer:resume()
            end
        end
    )
end

function cleanup()
    print_debug("stats")
    mp.msg.info("Cleanup.")
    -- Kill all timers
    for index in pairs(timers) do
        if timers[index]:is_enabled() then
            timers[index]:kill()
        end
    end
    -- Remove all timers
    timers = {}
    -- Remove all existing filters
    for _, value in pairs(labels) do
        remove_filter(value)
    end
    -- Reset some values
    stats, collected = {}, {}
    limit.current = options.detect_limit
end

local function init_source()
    local width = mp.get_property_native("width")
    local height = mp.get_property_native("height")
    source = {
        w = width,
        h = height,
        x = 0,
        y = 0
    }
    compute_meta(source)
    copy_meta(source, applied)
    compute_meta(applied)
    stats[source.whxy] = {counter = {applied = 1, detect = 0, last_seen = 0, potential = 0}}
    copy_meta(source, stats[source.whxy])
    compute_meta(stats[source.whxy])
    trusted_offset.y, trusted_offset.x = {0}, {0}
end

local function seek(name)
    print_debug(string.format("Stop by %s event.", name))
    if timers.periodic_timer and timers.periodic_timer:is_enabled() then
        timers.periodic_timer:kill()
        if timers.crop_detect then
            timers.crop_detect = nil
        end
    end
end

local function seek_event()
    seeking = true
end

local function resume(name)
    if timers.periodic_timer and not timers.periodic_timer:is_enabled() and not in_progress then
        timers.periodic_timer:resume()
        print_debug(string.format("Resumed by %s event.", name))
    end
    local playback_time = mp.get_property_native("playback-time")
    if timers.start_delay and timers.start_delay:is_enabled() and playback_time > options.start_delay then
        timers.start_delay.timeout = 0
        timers.start_delay:kill()
        timers.start_delay:resume()
    end
end

local function resume_event()
    seeking = false
end

function on_toggle(mode)
    if filter_missing then
        mp.osd_message("Libavfilter cropdetect missing", 3)
        return
    end
    if is_filter_present(labels.crop) and (clean_filter or options.mode >= 3) then
        remove_filter(labels.crop)
        remove_filter(labels.cropdetect)
        copy_meta(source, applied)
        compute_meta(applied)
        if options.mode <= 2 then
            clean_filter = false
            return
        end
    end
    if not toggled then
        toggled = true
        if not paused then
            seek("toggle")
        end
        mp.osd_message(string.format("%s paused.", label_prefix), 3)
    else
        toggled = false
        if not paused then
            resume("toggle")
        end
        mp.osd_message(string.format("%s resumed.", label_prefix), 3)
    end
    if mode then
        clean_filter = true
    end
end

local function pause(_, bool)
    if bool then
        paused = true
        seek("pause")
        print_debug("stats")
    else
        paused = false
        if not toggled then
            resume("unpause")
        end
    end
end

local function on_start()
    mp.msg.info("File loaded.")
    if not is_cropable() then
        mp.msg.warn("Exit, only works for videos.")
        return
    end

    init_source()

    mp.observe_property("osd-dimensions", "native", osd_size_change)

    local start_delay
    if options.mode ~= 2 then
        start_delay = 0
    else
        start_delay = options.start_delay
    end

    timers.start_delay =
        mp.add_timeout(
        start_delay,
        function()
            timers.periodic_timer = mp.add_periodic_timer(0, auto_crop)
        end
    )
end

mp.register_event("seek", seek_event)
mp.register_event("playback-restart", resume_event)
mp.observe_property("pause", "bool", pause)
mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
