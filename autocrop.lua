--[[
This script uses the lavfi cropdetect filter to automatically insert a crop filter with appropriate parameters for the
currently playing video, the script run continuously by default, base on periodic_timer and detect_seconds timer.

It will automatically crop the video, when playback starts.

Also It registers the key-binding "C" (shift+c). You can manually crop the video by pressing the "C" (shift+c) key.

If the "C" key is pressed again, the crop filter is removed restoring playback to its original state.

The workflow is as follows: First, it inserts the filter vf=lavfi=cropdetect. After <detect_seconds> (default is 1)
seconds, it then inserts the filter vf=crop=w:h:x:y, where w,h,x,y are determined from the vf-metadata gathered by
cropdetect. The cropdetect filter is removed immediately after the crop filter is inserted as it is no longer needed.

Since the crop parameters are determined from the 1 second of video between inserting the cropdetect and crop filters, the "C"
key should be pressed at a position in the video where the crop region is unambiguous (i.e., not a black frame, black background
title card, or dark scene).

The default options can be overridden by adding script-opts-append=autocrop-<parameter>=<value> into mpv.conf

List of available parameters (For default values, see <options>)：

auto: bool - Whether to automatically apply crop periodicly. 
    If you want a single crop at start, set it to false or add "script-opts-append=autocrop-auto=no" into mpv.conf.

periodic_timer: seconds - Delay between crop detect in auto mode.

detect_limit: number[0-255] - Black threshold for cropdetect.
    Smaller values will generally result in less cropping.
    See limit of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_round: number[2^n] -  The value which the width/height should be divisible by 2. Smaller values have better detection
    accuracy. If you have problems with other filters, you can try to set it to 4 or 16.
    See round of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_seconds: seconds - How long to gather cropdetect data.
    Increasing this may be desirable to allow cropdetect more time to collect data.

min/max_aspect_ratio: [21.6/9] or [2.4] - min_aspect_ratio is used to disable the script if the video is over that ratio (already crop).
    max_aspect_ratio is used to prevent cropping over that ratio.
--]]
require "mp.msg"
require "mp.options"

local options = {
    enable = true,
    auto = true,
    periodic_timer = 0,
    start_delay = 0,
    -- crop behavior
    min_aspect_ratio = 21.6 / 9,
    max_aspect_ratio = 21.6 / 9,
    width_pxl_margin = 4,
    height_pxl_margin = 4,
    height_pct_margin = 0.038,
    fixed_width = true,
    -- cropdetect
    detect_limit = 24,
    detect_round = 2,
    detect_seconds = 0.45
}
read_options(options)

if not options.enable then
    mp.msg.info("Disable script.")
    return
end

-- Init variables
local label_prefix = mp.get_script_name()
local labels = {
    crop = string.format("%s-crop", label_prefix),
    cropdetect = string.format("%s-cropdetect", label_prefix)
}
local height_pct_margin_up = (100 * options.height_pct_margin) / (100 - 100 * options.height_pct_margin)
local detect_seconds_adjust = options.detect_seconds
local limit_max = options.detect_limit
local limit_adjust = options.detect_limit
local limit_adjust_by = 1
local timers = {}
-- states
local in_progress, paused, toggled, seeking
-- metadata
local meta = {}
local entity = {"size_origin", "apply_current", "detect_current", "detect_last"}
local unit = {"w", "h", "x", "y"}
for k, v in pairs(entity) do
    meta[v] = {unit}
end
local meta_count = {}

function meta_copy(from, to)
    for k, v in pairs(unit) do
        to[v] = from[v]
    end
end

function meta_stats(meta, shape, debug)
    local sym, in_tol = 0, 0
    local is_majority, cond1_r, return_shape
    -- Shape Majority
    for k, k1 in pairs(meta_count) do
        if meta_count[k].shape_y == "Symmetric" then
            sym = sym + meta_count[k].count
        else
            in_tol = in_tol + meta_count[k].count
        end
    end
    if sym > in_tol then
        return_shape = true
        is_majority = "Symmetric"
    else
        return_shape = false
        is_majority = "In Tolerance"
    end

    -- Debug
    if debug then
        mp.msg.info("Meta Stats:")
        mp.msg.info(string.format("Shape majority is %s, %d > %d", is_majority, sym, in_tol))
        for k, k1 in pairs(meta_count) do
            if type(k) ~= "table" then
                mp.msg.info(string.format("%s count=%s shape_y=%s cond1=%s", k, meta_count[k].count, meta_count[k].shape_y, meta_count[k].cond1))
            end
        end
        return
    end

    local meta_whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y)
    if not meta_count[meta_whxy] then
        meta_count[meta_whxy] = {unit}
        meta_count[meta_whxy].count = 0
        meta_count[meta_whxy].shape_y = shape
        meta_copy(meta, meta_count[meta_whxy])
    end
    meta_count[meta_whxy].count = meta_count[meta_whxy].count + 1

    -- Cond1
    --[[ for k, k1 in pairs(meta_count) do
        cond1_y, cond1_n = 0, 0
        for k2, k3 in pairs(meta_count) do
            if meta_count[k] ~= meta_count[k2] then
                if meta_count[k].shape_y == is_majority and meta_count[k].count / 5 > meta_count[k2].count then
                    cond1_y = cond1_y + 1
                else
                    cond1_n = cond1_n + 1
                end
            end
        end

        if cond1_y > cond1_n or (cond1_y + cond1_n) == 0 then
            cond1_r = true
            meta_count[k].cond1 = "yes"
        else
            cond1_r = false
            meta_count[k].cond1 = "no"
        end
    end ]]

    return return_shape
end

function init_size()
    local width = mp.get_property_native("width")
    local height = mp.get_property_native("height")
    meta.size_origin = {
        w = width,
        h = height,
        x = 0,
        y = 0
    }
    meta_copy(meta.size_origin, meta.apply_current)
end

function is_filter_present(label)
    local filters = mp.get_property_native("vf")
    for index, filter in pairs(filters) do
        if filter["label"] == label then
            return true
        end
    end
    return false
end

function is_enough_time(seconds)
    local time_needed = seconds + 1
    local playtime_remaining = mp.get_property_native("playtime-remaining")
    if playtime_remaining and time_needed > playtime_remaining then
        mp.msg.warn("Not enough time for autocrop.")
        seek("no-time")
        return false
    end
    return true
end

function is_cropable()
    local vid = mp.get_property_native("vid")
    local is_album = vid and mp.get_property_native(string.format("track-list/%s/albumart", vid)) or false
    return vid and not is_album
end

function insert_crop_filter()
    local insert_crop_filter_command =
        mp.command(string.format("no-osd vf pre @%s:lavfi-cropdetect=limit=%d/255:round=%d:reset=0", labels.cropdetect, limit_adjust, options.detect_round))
    if not insert_crop_filter_command then
        mp.msg.error("Does vf=help as #1 line in mvp.conf return libavfilter list with crop/cropdetect in log?")
        cleanup()
        return false
    end
    return true
end

function remove_filter(label)
    if is_filter_present(label) then
        mp.command(string.format("no-osd vf remove @%s", label))
    end
end

function collect_metadata()
    local cropdetect_metadata
    repeat
        cropdetect_metadata = mp.get_property_native(string.format("vf-metadata/%s", labels.cropdetect))
        if paused or toggled or seeking then
            break
        end
    until cropdetect_metadata and cropdetect_metadata["lavfi.cropdetect.w"]
    -- Remove filter to reset detection.
    remove_filter(labels.cropdetect)
    if cropdetect_metadata and cropdetect_metadata["lavfi.cropdetect.w"] then
        -- Make metadata usable.
        meta.detect_current = {
            w = tonumber(cropdetect_metadata["lavfi.cropdetect.w"]),
            h = tonumber(cropdetect_metadata["lavfi.cropdetect.h"]),
            x = tonumber(cropdetect_metadata["lavfi.cropdetect.x"]),
            y = tonumber(cropdetect_metadata["lavfi.cropdetect.y"])
        }
        if meta.detect_current.w < 0 or meta.detect_current.h < 0 then
            -- Invalid data, probably a black screen
            detect_seconds_adjust = options.detect_seconds
            return false
        end
        return true
    end
    return false
end

function auto_crop()
    -- Pause auto_crop
    in_progress = true
    timers.periodic_timer:stop()

    -- Verify if there is enough time to detect crop.
    local time_needed = detect_seconds_adjust
    if not is_enough_time(time_needed) then
        return
    end

    if not insert_crop_filter() then
        return
    end

    -- Wait to gather data.
    timers.crop_detect =
        mp.add_timeout(
        time_needed,
        function()
            if collect_metadata() and not paused and not toggled then
                if options.fixed_width then
                    meta.detect_current.w = meta.size_origin.w
                    meta.detect_current.x = meta.size_origin.x
                end

                local not_already_apply = meta.detect_current.h ~= meta.apply_current.h or meta.detect_current.w ~= meta.apply_current.w
                local symmetric_x = meta.detect_current.x == (meta.size_origin.w - meta.detect_current.w) / 2
                local symmetric_y = meta.detect_current.y == (meta.size_origin.h - meta.detect_current.h) / 2
                local in_margin_y =
                    meta.detect_current.y >= (meta.size_origin.h - meta.detect_current.h - options.height_pxl_margin) / 2 and
                    meta.detect_current.y <= (meta.size_origin.h - meta.detect_current.h + options.height_pxl_margin) / 2
                local pxl_change_h =
                    meta.detect_current.h >= meta.apply_current.h - options.height_pxl_margin and
                    meta.detect_current.h <= meta.apply_current.h + options.height_pxl_margin
                local pct_change_h =
                    meta.detect_current.h >= meta.apply_current.h - meta.apply_current.h * options.height_pct_margin and
                    meta.detect_current.h <= meta.apply_current.h + meta.apply_current.h * height_pct_margin_up
                local max_aspect_ratio_h = meta.detect_current.h >= meta.size_origin.w / options.max_aspect_ratio
                local detect_confirmation = meta.detect_current.h == meta.detect_last.h
                local detect_size_origin = meta.detect_current.h == meta.size_origin.h

                local shape_current_y
                if symmetric_y then
                    shape_current_y = "Symmetric"
                elseif in_margin_y then
                    shape_current_y = "In margin"
                else
                    shape_current_y = "Asymmetric"
                end

                -- Debug cropdetect meta
                --[[ mp.msg.info(
                    string.format(
                        "detect_curr=w=%s:h=%s:x=%s:y=%s, Y:%s",
                        meta.detect_current.w,
                        meta.detect_current.h,
                        meta.detect_current.x,
                        meta.detect_current.y,
                        shape_current_y
                    )
                ) ]]

                -- Store valid crop meta
                local detect_shape_y
                if in_margin_y and max_aspect_ratio_h then
                    if meta_stats(meta.detect_current, shape_current_y) then
                        detect_shape_y = symmetric_y
                    end
                else
                    detect_shape_y = in_margin_y
                end

                -- Auto adjust black threshold and detect_seconds
                if in_margin_y then
                    if limit_adjust < limit_max then
                        if detect_size_origin then
                            if limit_adjust + limit_adjust_by + 1 <= limit_max then
                                limit_adjust = limit_adjust + limit_adjust_by + 1
                            else
                                limit_adjust = limit_max
                            end
                        end
                    end
                    detect_seconds_adjust = options.detect_seconds
                else
                    if limit_adjust > 0 then
                        if limit_adjust - limit_adjust_by >= 0 then
                            limit_adjust = limit_adjust - limit_adjust_by
                        else
                            limit_adjust = 0
                        end
                        detect_seconds_adjust = 0
                    end
                end

                -- Crop Filter:
                local crop_filter = not_already_apply and symmetric_x and detect_shape_y and (pxl_change_h or not pct_change_h) and max_aspect_ratio_h and detect_confirmation

                if crop_filter then
                    -- Apply crop.
                    mp.command(
                        string.format(
                            "no-osd vf pre @%s:lavfi-crop=w=%s:h=%s:x=%s:y=%s",
                            labels.crop,
                            meta.detect_current.w,
                            meta.detect_current.h,
                            meta.detect_current.x,
                            meta.detect_current.y
                        )
                    )
                    -- Save values to compare later.
                    meta_copy(meta.detect_current, meta.apply_current)
                end
                meta_copy(meta.detect_current, meta.detect_last)
            end
            -- Resume auto_crop
            in_progress = false
            if not paused and not toggled then
                timers.periodic_timer:resume()
            end
        end
    )
end

function cleanup()
    mp.msg.info("Cleanup.")
    -- Kill all timers.
    for index, value in pairs(timers) do
        if timers[index]:is_enabled() then
            timers[index]:kill()
        end
    end
    -- Remove all timers.
    timers = {}

    -- Remove all existing filters.
    for key, value in pairs(labels) do
        remove_filter(value)
    end

    -- Reset some values
    meta_count = {}
    meta.size_origin = {}
    limit_adjust = options.detect_limit
end

function on_start()
    if not is_cropable() then
        mp.msg.warn("Only works for videos.")
        return
    end

    init_size()

    if options.min_aspect_ratio < meta.size_origin.w / meta.size_origin.h then
        mp.msg.info("Disable script, Aspect Ratio > min_aspect_ratio.")
        return
    end

    timers.start_delay =
        mp.add_timeout(
        options.start_delay,
        function()
            -- Run periodic or once.
            if options.auto then
                local time_needed = options.periodic_timer
                timers.periodic_timer = mp.add_periodic_timer(time_needed, auto_crop)
            else
                auto_crop()
            end
        end
    )
end

function seek(name)
    mp.msg.info(string.format("Stop by %s event.", name))
    meta_stats(_, _, true)
    if timers.periodic_timer and timers.periodic_timer:is_enabled() then
        timers.periodic_timer:kill()
        if timers.crop_detect and timers.crop_detect:is_enabled() then
            timers.crop_detect:kill()
        end
    end
end

function seek_event()
    seeking = true
end

function resume(name)
    if timers.periodic_timer and not timers.periodic_timer:is_enabled() and not in_progress then
        timers.periodic_timer:resume()
        mp.msg.info(string.format("Resumed by %s event.", name))
    end

    local playback_time = mp.get_property_native("playback-time")
    if timers.start_delay and timers.start_delay:is_enabled() and playback_time > options.start_delay then
        timers.start_delay.timeout = 0
        timers.start_delay:kill()
        timers.start_delay:resume()
    end
end

function resume_event()
    seeking = false
end

function on_toggle()
    if not options.auto then
        auto_crop()
        mp.osd_message(string.format("%s once.", label_prefix), 3)
    else
        if is_filter_present(labels.crop) then
            remove_filter(labels.crop)
            remove_filter(labels.cropdetect)
            meta_copy(meta.size_origin, meta.apply_current)
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
    end
end

function pause(_, bool)
    if options.auto then
        if bool then
            paused = true
            seek("pause")
        else
            paused = false
            if not toggled then
                resume("unpause")
            end
        end
    end
end

mp.register_event("seek", seek_event)
mp.register_event("playback-restart", resume_event)
mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.observe_property("pause", "bool", pause)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
