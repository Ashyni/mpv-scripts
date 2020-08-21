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

auto: bool - Whether to automatically apply crop at the start of
    playback. If you don't want to crop automatically, set it to
    false or add "script-opts-append=autocrop-auto=no" into
    mpv.conf.

auto_delay: seconds - Delay before starting crop in auto mode.
    You can try to increase this value to avoid dark scene or
    fade in at beginning. Automatic cropping will not occur if
    the value is larger than the remaining playback time.

detect_limit: number[0-255] - Black threshold for cropdetect.
    Smaller values will generally result in less cropping.
    See limit of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_round: number[2^n] -  The value which the width/height
    should be divisible by. Smaller values ​​have better detection
    accuracy. If you have problems with other filters,
    you can try to set it to 4 or 16.
    See round of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_seconds: seconds - How long to gather cropdetect data.
    Increasing this may be desirable to allow cropdetect more
    time to collect data.
--]]
require "mp.msg"
require "mp.options"

local options = {
    enable = true,
    auto = true,
    auto_delay = 0,
    start_delay = 0,
    -- crop behavior
    detect_min_aspect_ratio = 16 / 9,
    detect_max_aspect_ratio = 22 / 9,
    detect_max_w_pixel = 8,
    detect_max_h_pixel = 8,
    fixed_width = true,
    ignore_small_heigth = true,
    -- cropdetect
    detect_limit = 24,
    detect_round = 2,
    detect_seconds = 0.5,
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
local meta = {}
local meta_last = {}

function native_width_height()
    local width = mp.get_property_native("width")
    local height = mp.get_property_native("height")
    return width, height
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

function remove_filter(label)
    if is_filter_present(label) then
        mp.command(string.format("no-osd vf remove @%s", label))
        return true
    end
    return false
end

function init_size()
    local width, height = native_width_height()
    meta_last = {
        w = width,
        h = height,
        x = 0,
        y = 0
    }
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
end

function auto_crop()
    -- Verify if there is enough time to detect crop.
    local time_needed = options.detect_seconds

    if is_enough_time(time_needed) then
        return
    end

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

    -- Wait to gather data.
    timers.crop_detect =
        mp.add_timeout(
        time_needed,
        function()
            -- Get the metadata and remove the cropdetect filter.
            local cropdetect_metadata = mp.get_property_native(string.format("vf-metadata/%s", labels.cropdetect))
            remove_filter(labels.cropdetect)

            -- Remove the timer of detect crop.
            if timers.crop_detect:is_enabled() then
                timers.crop_detect:kill()
            end

            -- Verify the existence of metadata.
            if cropdetect_metadata then
                meta = {
                    w = cropdetect_metadata["lavfi.cropdetect.w"],
                    h = cropdetect_metadata["lavfi.cropdetect.h"],
                    x = cropdetect_metadata["lavfi.cropdetect.x"],
                    y = cropdetect_metadata["lavfi.cropdetect.y"]
                }
            else
                mp.msg.error("No crop data.")
                mp.msg.info("Was the cropdetect filter successfully inserted?")
                mp.msg.info("Does your version of ffmpeg/libav support AVFrame metadata?")
                return
            end

            -- Verify that the metadata meets the requirements and convert it.
            if meta.w and meta.h and meta.x and meta.y then
                local width, height = native_width_height()
                meta = {
                    w = tonumber(meta.w),
                    h = tonumber(meta.h),
                    x = tonumber(meta.x),
                    y = tonumber(meta.y),
                    max_w_pixel = width - options.detect_max_w_pixel,
                    max_h_pixel = height - options.detect_max_h_pixel,
                    max_w = width,
                    max_h = height
                }
            else
                mp.msg.error("Got empty crop data.")
                mp.msg.info("You might need to increase detect_seconds.")
                return
            end

            -- Debug crop detect raw value
            mp.msg.debug(string.format("pre-filter-crop=w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y))

            -- Detect dark scene, adjust cropdetect limit
            -- between 0 and detect_limit
            local light_scene =
                (meta.x >= (meta.max_w_pixel - meta.w) / 2 and meta.x <= (meta.max_w - meta.w) / 2) and
                (meta.y >= (meta.max_h_pixel - meta.h) / 2 and meta.y <= (meta.max_h - meta.h) / 2)

            -- Scale adjustement on detect_limit, min 1
            local limit_adjust_by = (limit_adjust - limit_adjust % 10) / 10
            if limit_adjust_by == 0 then
                limit_adjust_by = 1
            end

            if not light_scene then
                if limit_adjust - limit_adjust_by >= limit_adjust_by then
                    limit_adjust = limit_adjust - limit_adjust_by
                else
                    limit_adjust = 0
                end
                -- Debug limit_adjust change
                mp.msg.debug(string.format("limit_adjust=%s", limit_adjust))
                return
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

            -- Crop Filter:
            -- Prevent apply same crop as previous.
            -- Prevent crop bigger than 22/9 aspect ratio.
            -- Prevent asymmetric crop with slight tolerance.
            -- Prevent small width change.
            -- Prevent small heigh change.
            local crop_filter =
                (meta.h ~= meta_last.h or meta.w ~= meta_last.w or meta.x ~= meta_last.x or meta.y ~= meta_last.y) and
                meta.h >= meta.max_w / options.detect_max_aspect_ratio and
                meta.w >= meta.max_w_pixel and
                (meta.x >= (meta.max_w_pixel - meta.w) / 2 and meta.x <= (meta.max_w - meta.w) / 2) and
                (meta.y >= (meta.max_h_pixel - meta.h) / 2 and meta.y <= (meta.max_h - meta.h) / 2) and
                (not options.fixed_width or options.fixed_width and meta.h ~= meta_last.h) and
                (not options.ignore_small_heigth or
                    options.ignore_small_heigth and
                        (meta.h > meta_last.h + options.detect_max_h_pixel or
                            meta.h < meta_last.h - options.detect_max_h_pixel))

            if crop_filter then
                if options.fixed_width then
                    meta.w = meta.max_w
                    meta.x = 0
                end

                -- Remove existing crop.
                remove_filter(labels.crop)
                -- Apply crop.
                mp.command(
                    string.format(
                        "no-osd vf pre @%s:lavfi-crop=w=%s:h=%s:x=%s:y=%s",
                        labels.crop,
                        meta.w,
                        meta.h,
                        meta.x,
                        meta.y
                    )
                )

                --Debug apply crop
                mp.msg.debug(string.format("apply-crop=w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y))

                -- Save values to compare later.
                meta_last = {
                    w = meta.w,
                    h = meta.h,
                    x = meta.x,
                    y = meta.y
                }
            else
                return
            end
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
    elseif options.detect_min_aspect_ratio < width / height then
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
                local time_needed = options.auto_delay + options.detect_seconds + 0.1
                -- Verify if there is enough time for autocrop.
                if is_enough_time(time_needed) then
                    return
                end
                timers.auto_delay = mp.add_periodic_timer(time_needed, auto_crop)
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
        if timers.auto_delay:is_enabled() then
            seek()
            init_size()
            mp.osd_message("Autocrop paused.", 3)
            -- Cropped => Remove it.
            if remove_filter(labels.crop) then
                return
            end
        else
            resume()
            mp.osd_message("Autocrop resumed.", 3)
        end
    end
end

function seek(log)
    if timers.auto_delay and timers.auto_delay:is_enabled() then
        if log ~= false then
            mp.msg.warn("Seek.")
        end
        timers.auto_delay:kill()
        if timers.crop_detect and timers.crop_detect:is_enabled() then
            timers.crop_detect:kill()
        end
    end
end

function resume(log)
    if timers.auto_delay and not timers.auto_delay:is_enabled() then
        if log ~= false then
            mp.msg.warn("Resume.")
        end
        timers.auto_delay:resume()
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

mp.observe_property("pause", "bool", pause)
mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
