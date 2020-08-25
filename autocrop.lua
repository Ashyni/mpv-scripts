--[[
This script uses the lavfi cropdetect filter to automatically
insert a crop filter with appropriate parameters for the
currently playing video.

It will automatically crop the video, when playback starts.

Also It registers the key-binding "C" (shift+c). You can manually
crop the video by pressing the "C" (shift+c) key.

If the "C" key is pressed again, the crop filter is removed
restoring playback to its original state.

The workflow is as follows: First, it inserts the filter
vf=lavfi=cropdetect. After <detect_seconds> (default is 1)
seconds, it then inserts the filter vf=crop=w:h:x:y, where
w,h,x,y are determined from the vf-metadata gathered by
cropdetect. The cropdetect filter is removed immediately after
the crop filter is inserted as it is no longer needed.

Since the crop parameters are determined from the 1 second of
video between inserting the cropdetect and crop filters, the "C"
key should be pressed at a position in the video where the crop
region is unambiguous (i.e., not a black frame, black background
title card, or dark scene).

The default options can be overridden by adding
script-opts-append=autocrop-<parameter>=<value> into mpv.conf

List of available parameters (For default values, see <options>)：

auto: bool - Whether to automatically apply crop periodicly. 
    If you want a single crop at start, set it to
    false or add "script-opts-append=autocrop-auto=no" into
    mpv.conf.

periodic_timer: seconds - Delay before starting crop in auto mode.

detect_limit: number[0-255] - Black threshold for cropdetect.
    Smaller values will generally result in less cropping.
    See limit of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_round: number[2^n] -  The value which the width/height
    should be divisible by. Smaller values have better detection
    accuracy. If you have problems with other filters,
    you can try to set it to 4 or 16.
    See round of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_seconds: seconds - How long to gather cropdetect data.
    Increasing this may be desirable to allow cropdetect more
    time to collect data.

xxx_aspect_ratio: [21.6/9] or [2.4]
--]]
require "mp.msg"
require "mp.options"

local options = {
    enable = true,
    auto = true,
    periodic_timer = 0.1,
    start_delay = 0,
    -- crop behavior
    min_aspect_ratio = 16 / 9,
    max_aspect_ratio = 21.6 / 9,
    width_pixel_tolerance = 8,
    height_pixel_tolerance = 8,
    fixed_width = true,
    -- cropdetect
    detect_limit_min = 0,
    detect_limit = 24,
    detect_round = 2,
    detect_seconds = 0.4,
    reset = 0
}
read_options(options)

local label_prefix = mp.get_script_name()
local labels = {
    crop = string.format("%s-crop", label_prefix),
    cropdetect = string.format("%s-cropdetect", label_prefix)
}
local limit_adjust = options.detect_limit
local timers = {}

-- Multi-Dimensional Array metadata
meta = {}
key1 = {"size_origin", "size_precrop", "apply_current", "apply_last", "detect_current", "detect_last"}
key2 = {"w", "h", "x", "y"}
for k, v in pairs(key1) do
    meta[v] = {key2}
end

function native_width_height()
    local width = mp.get_property_native("width")
    local height = mp.get_property_native("height")
    return width, height
end

function init_size()
    local width, height = native_width_height()
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
    -- Plus 1 second for deviation.
    local time_needed = seconds + 1
    local playtime_remaining = mp.get_property_native("playtime-remaining")
    if playtime_remaining and time_needed > playtime_remaining then
        mp.msg.warn("Not enough time for autocrop.")
        return false
    end
end

function is_cropable()
    local vid = mp.get_property_native("vid")
    local is_album = vid and mp.get_property_native(string.format("track-list/%s/albumart", vid)) or false

    return vid and not is_album
end

function insert_crop_filter()
    -- Insert the cropdetect filter.
    local limit = options.detect_limit
    local round = options.detect_round
    local reset = options.reset

    mp.command(
        string.format(
            "no-osd vf pre @%s:cropdetect=limit=%d/255:round=%d:reset=%d",
            labels.cropdetect,
            limit_adjust,
            round,
            reset
        )
    )
end

function collect_metadata()
    -- Get the metadata and remove the cropdetect filter.
    local cropdetect_metadata = mp.get_property_native(string.format("vf-metadata/%s", labels.cropdetect))
    remove_filter(labels.cropdetect)

    -- Remove the timer of detect crop.
    if timers.crop_detect:is_enabled() then
        timers.crop_detect:kill()
    end

    -- Verify the existence of metadata and make them usable.
    if cropdetect_metadata then
        meta.detect_current = {
            w = tonumber(cropdetect_metadata["lavfi.cropdetect.w"]),
            h = tonumber(cropdetect_metadata["lavfi.cropdetect.h"]),
            x = tonumber(cropdetect_metadata["lavfi.cropdetect.x"]),
            y = tonumber(cropdetect_metadata["lavfi.cropdetect.y"])
        }
        return true
    else
        mp.msg.error("No crop data.")
        mp.msg.info("Was the cropdetect filter successfully inserted?")
        mp.msg.info("Does your version of ffmpeg/libav support AVFrame metadata?")
        return false
    end
end

function remove_filter(label)
    if is_filter_present(label) then
        mp.command(string.format("no-osd vf remove @%s", label))
    end
end

function cleanup()
    -- Remove all existing filters.
    for key, value in pairs(labels) do
        remove_filter(value)
    end

    -- Kill all timers.
    for index, timer in pairs(timers) do
        if timer then
            timer:kill()
            timer = nil
        end
    end

    -- Reset meta.size
    meta.size_origin = {}
    meta.size_precrop = {}
end

function pre_crop()
    local time_needed = options.detect_seconds
    if is_enough_time(time_needed) then
        return
    end

    insert_crop_filter()

    timers.crop_detect =
        mp.add_timeout(
        time_needed,
        function()
            if not collect_metadata() then
                return
            end

            local precrop =
                meta.detect_current.w >= meta.size_origin.w - options.width_pixel_tolerance and
                meta.detect_current.h >= meta.size_origin.h - options.height_pixel_tolerance and
                (meta.detect_current.x >=
                    (meta.size_origin.w - options.width_pixel_tolerance - meta.detect_current.w) / 2 and
                    meta.detect_current.x <= (meta.size_origin.w - meta.detect_current.w) / 2) and
                (meta.detect_current.y >=
                    (meta.size_origin.h - options.width_pixel_tolerance - meta.detect_current.h) / 2 and
                    meta.detect_current.y <= (meta.size_origin.h - meta.detect_current.h) / 2)

            if precrop then
                meta.size_precrop = meta.detect_current
            else
                meta.size_precrop = meta.size_origin
            end
            mp.msg.info(
                string.format(
                    "pre-crop=w=%s:h=%s:x=%s:y=%s",
                    meta.size_precrop.w,
                    meta.size_precrop.h,
                    meta.size_precrop.x,
                    meta.size_precrop.y
                )
            )
            timers.periodic_timer:resume()
        end
    )
end

function auto_crop()
    -- Check if pre_crop() is already done.
    if not meta.size_precrop.w then
        timers.periodic_timer:kill()
        pre_crop()
    end

    -- Verify if there is enough time to detect crop.
    local time_needed = options.detect_seconds
    if is_enough_time(time_needed) then
        return
    end

    insert_crop_filter()

    -- Wait to gather data.
    timers.crop_detect =
        mp.add_timeout(
        time_needed,
        function()
            if not collect_metadata() then
                return
            end

            -- Debug crop detect raw value

            mp.msg.debug(
                string.format(
                    "detect_last=w=%s:h=%s:x=%s:y=%s",
                    meta.detect_last.w,
                    meta.detect_last.h,
                    meta.detect_last.x,
                    meta.detect_last.y
                )
            )

            mp.msg.debug(
                string.format(
                    "detect_curr=w=%s:h=%s:x=%s:y=%s",
                    meta.detect_current.w,
                    meta.detect_current.h,
                    meta.detect_current.x,
                    meta.detect_current.y
                )
            )
            mp.msg.debug(
                string.format(
                    "apply_curr=w=%s:h=%s:x=%s:y=%s",
                    meta.apply_current.w,
                    meta.apply_current.h,
                    meta.apply_current.x,
                    meta.apply_current.y
                )
            )

            -- Detect dark scene, adjust cropdetect limit
            -- between detect_limit_min and detect_limit
            local dark_scene =
                meta.detect_current.y == (meta.size_precrop.h - meta.detect_current.h) / 2 or
                meta.detect_current.x == (meta.size_precrop.w - meta.detect_current.w) / 2

            -- Scale adjustement on detect_limit, min 1
            local limit_adjust_by = (limit_adjust - limit_adjust % 10) / 10
            local limit_adjust_by = ((limit_adjust - limit_adjust_by) - (limit_adjust - limit_adjust_by) % 10) / 10
            if limit_adjust_by == 0 then
                limit_adjust_by = 1
            end

            local limit = options.detect_limit
            if not dark_scene then
                if limit_adjust > options.detect_limit_min then
                    if limit_adjust - limit_adjust_by >= options.detect_limit_min then
                        limit_adjust = limit_adjust - limit_adjust_by
                    else
                        limit_adjust = options.detect_limit_min
                    end
                    -- Debug limit_adjust change
                    mp.msg.debug(string.format("limit_adjust=%s", limit_adjust))
                end
            else
                if limit_adjust < limit then
                    if limit_adjust + limit_adjust_by * 2 <= limit then
                        limit_adjust = limit_adjust + limit_adjust_by * 2
                    else
                        limit_adjust = limit
                    end
                    -- Debug limit_adjust change
                    mp.msg.debug(string.format("limit_adjust=%s", limit_adjust))
                end
            end

            if options.fixed_width then
                meta.detect_current.w = meta.size_precrop.w
                meta.detect_current.x = meta.size_precrop.x
            end

            -- Crop Filter:
            -- Prevent apply same crop as previous.
            -- Prevent crop bigger than max_aspect_ratio.
            -- Prevent asymmetric crop.
            -- Confirm with last detect to avoid false positive.
            local crop_filter =
                (meta.detect_current.h ~= meta.apply_current.h or meta.detect_current.w ~= meta.apply_current.w) and
                meta.detect_current.x == (meta.size_precrop.w - meta.detect_current.w) / 2 and
                meta.detect_current.y == (meta.size_precrop.h - meta.detect_current.h) / 2 and
                meta.detect_current.h >= meta.size_precrop.w / options.max_aspect_ratio and
                meta.detect_current.h == meta.detect_last.h

            if crop_filter then
                -- Remove existing crop.
                remove_filter(labels.crop)
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

                --Debug apply crop
                mp.msg.debug(
                    string.format(
                        "apply-last=w=%s:h=%s:x=%s:y=%s",
                        meta.apply_last.w,
                        meta.apply_last.h,
                        meta.apply_last.x,
                        meta.apply_last.y
                    )
                )
                mp.msg.debug(
                    string.format(
                        "apply-curr=w=%s:h=%s:x=%s:y=%s",
                        meta.apply_current.w,
                        meta.apply_current.h,
                        meta.apply_current.x,
                        meta.apply_current.y
                    )
                )

                -- Save values to compare later.
                meta.apply_last = {
                    w = meta.apply_current.w,
                    h = meta.apply_current.h,
                    x = meta.apply_current.x,
                    y = meta.apply_current.y
                }
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
    )
end

function on_start()
    -- Clean up at the beginning.
    cleanup()

    local width, height = native_width_height()

    if not options.enable then
        mp.msg.info("Disable script.")
        return
    elseif not is_cropable() then
        mp.msg.warn("Only works for videos.")
        return
    elseif options.min_aspect_ratio < width / height then
        mp.msg.info("Disable script, AR > min_aspect_ratio.")
        return
    end

    init_size()

    timers.start_delay =
        mp.add_timeout(
        options.start_delay,
        function()
            -- Run periodic or once.
            if options.auto then
                local time_needed = options.periodic_timer + options.detect_seconds
                -- Verify if there is enough time for autocrop.
                if is_enough_time(time_needed) then
                    return
                end

                timers.periodic_timer = mp.add_periodic_timer(time_needed, auto_crop)
            else
                auto_crop()
            end
        end
    )
end

function on_toggle()
    if not options.auto then
        auto_crop()
        mp.osd_message("Autocrop once.", 3)
    else
        if timers.periodic_timer:is_enabled() then
            seek()
            init_size()
            remove_filter(labels.crop)
            remove_filter(labels.cropdetect)
            mp.osd_message("Autocrop paused.", 3)
        else
            resume()
            mp.osd_message("Autocrop resumed.", 3)
        end
    end
end

function seek(log)
    if timers.periodic_timer and timers.periodic_timer:is_enabled() then
        if log ~= false then
            mp.msg.warn("Seek.")
        end
        timers.periodic_timer:kill()
        if timers.crop_detect and timers.crop_detect:is_enabled() then
            timers.crop_detect:kill()
        end
    end
end

function resume(log)
    if timers.periodic_timer and not timers.periodic_timer:is_enabled() then
        if log ~= false then
            mp.msg.warn("Resume.")
        end
        timers.periodic_timer:resume()
    end
end

function pause(_, bool)
    if options.auto then
        if bool then
            mp.msg.warn("Paused.")
            seek(false)
            mp.unregister_event("seek")
            mp.unregister_event("playback-restart")
        else
            mp.msg.warn("Unpaused.")
            resume(false)
            mp.register_event("seek", seek)
            mp.register_event("playback-restart", resume)
        end
    end
end

mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.observe_property("pause", "bool", pause)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
