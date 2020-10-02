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
    width_pixel_tolerance = 4,
    height_pixel_tolerance = 4,
    height_pct_tolerance = 0.038,
    fixed_width = true,
    -- cropdetect
    detect_limit = 24,
    detect_round = 2,
    detect_seconds = 0.4,
    reset = 0
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
local height_pct_tolerance_up = (100 * options.height_pct_tolerance) / (100 - 100 * options.height_pct_tolerance)
local limit_max = options.detect_limit
local limit_adjust = options.detect_limit
local limit_adjust_by = 1
local timers = {}
-- states
local in_progress = nil
local paused = nil
local toggled = nil
local seeking = nil
-- metadata
local meta = {}
local key1 = {"size_origin", "apply_current", "detect_current", "detect_last"}
local key2 = {"w", "h", "x", "y"}
for k, v in pairs(key1) do
    meta[v] = {key2}
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
    meta.apply_current = meta.size_origin
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
        mp.command(string.format("no-osd vf pre @%s:lavfi-cropdetect=limit=%d/255:round=%d:reset=%d", labels.cropdetect, limit_adjust, options.detect_round, options.reset))
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
    -- Get the metadata and remove the cropdetect filter.
    local cropdetect_metadata = mp.get_property_native(string.format("vf-metadata/%s", labels.cropdetect))
    remove_filter(labels.cropdetect)

    -- Verify the existence of metadata and make them usable.
    if cropdetect_metadata then
        meta.detect_current = {
            w = tonumber(cropdetect_metadata["lavfi.cropdetect.w"]),
            h = tonumber(cropdetect_metadata["lavfi.cropdetect.h"]),
            x = tonumber(cropdetect_metadata["lavfi.cropdetect.x"]),
            y = tonumber(cropdetect_metadata["lavfi.cropdetect.y"])
        }
        if not (meta.detect_current.w and meta.detect_current.h and meta.detect_current.x and meta.detect_current.y) then
            if not seeking and not paused and not toggled then
                mp.msg.warn("Empty crop data. If repeated, increase detect_seconds")
            end
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
    local time_needed = options.detect_seconds
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

                local not_already_apply = (meta.detect_current.h ~= meta.apply_current.h or meta.detect_current.w ~= meta.apply_current.w)
                local invalid_h = meta.detect_current.h < 0
                local symmetric_x = not invalid_h and meta.detect_current.x == (meta.size_origin.w - meta.detect_current.w) / 2
                local symmetric_y = not invalid_h and meta.detect_current.y == (meta.size_origin.h - meta.detect_current.h) / 2
                local in_tolerance_y =
                    not invalid_h and meta.detect_current.y >= (meta.size_origin.h - meta.detect_current.h - options.height_pixel_tolerance) / 2 and
                    meta.detect_current.y <= (meta.size_origin.h - meta.detect_current.h + options.height_pixel_tolerance) / 2
                local height_pxl_change =
                    meta.detect_current.h >= meta.apply_current.h - options.height_pixel_tolerance and
                    meta.detect_current.h <= meta.apply_current.h + options.height_pixel_tolerance
                local height_pct_change =
                    meta.detect_current.h >= meta.apply_current.h - meta.apply_current.h * options.height_pct_tolerance and
                    meta.detect_current.h <= meta.apply_current.h + meta.apply_current.h * height_pct_tolerance_up
                local max_aspect_ratio_h = meta.detect_current.h >= meta.size_origin.w / options.max_aspect_ratio
                local detect_confirmation = meta.detect_current.h == meta.detect_last.h
                local detect_size_origin = meta.detect_current.h == meta.size_origin.h

                -- Debug crop detect raw value
                --[[ local state_current_y
                if symmetric_y then
                    state_current_y = "Symmetric"
                elseif in_tolerance_y then
                    state_current_y = "In tolerance"
                elseif not invalid_h then
                    state_current_y = "Asymmetric"
                else
                    state_current_y = "Invalid"
                end ]]
                -- mp.msg.debug(string.format("detect_last=w=%s:h=%s:x=%s:y=%s", meta.detect_last.w, meta.detect_last.h, meta.detect_last.x, meta.detect_last.y))
                --[[ mp.msg.info(
                    string.format(
                        "detect_curr=w=%s:h=%s:x=%s:y=%s, Y:%s",
                        meta.detect_current.w,
                        meta.detect_current.h,
                        meta.detect_current.x,
                        meta.detect_current.y,
                        state_current_y
                    )
                ) ]]
                -- mp.msg.debug(string.format("apply_curr=w=%s:h=%s:x=%s:y=%s", meta.apply_current.w, meta.apply_current.h, meta.apply_current.x, meta.apply_current.y))
                -- mp.msg.debug(string.format("size_origin=w=%s:h=%s detect_current:w=%s:h=%s", meta.size_origin.w, meta.size_origin.h, meta.detect_current.w, meta.detect_current.h))

                -- Auto adjust black threshold
                if not invalid_h then
                    if in_tolerance_y then
                        if limit_adjust < limit_max then
                            if detect_size_origin then
                                if limit_adjust + limit_adjust_by + 1 <= limit_max then
                                    limit_adjust = limit_adjust + limit_adjust_by + 1
                                else
                                    limit_adjust = limit_max
                                end
                            end
                        end
                    else
                        if limit_adjust > 0 then
                            if limit_adjust - limit_adjust_by >= 0 then
                                limit_adjust = limit_adjust - limit_adjust_by
                            else
                                limit_adjust = 0
                            end
                        end
                    end
                end

                -- Crop Filter:
                local crop_filter =
                    not_already_apply and symmetric_x and in_tolerance_y and not height_pxl_change and not height_pct_change and max_aspect_ratio_h and detect_confirmation

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
                    meta.apply_current = {
                        w = meta.detect_current.w,
                        h = meta.detect_current.h,
                        x = meta.detect_current.x,
                        y = meta.detect_current.y
                    }
                end
                meta.detect_last = {
                    w = meta.detect_current.w,
                    h = meta.detect_current.h,
                    x = meta.detect_current.x,
                    y = meta.detect_current.y
                }
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
    mp.msg.info(string.format("Resumed by %s event.", name))
    if timers.periodic_timer and not timers.periodic_timer:is_enabled() and not in_progress then
        timers.periodic_timer:resume()
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
            meta.apply_current = meta.size_origin
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
