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

periodic_timer: seconds - Delay between full cycle.

start_delay: seconds - Delay use by mode = 2 (single-start), to skip intro.

prevent_change_mode: [0-2] 0 any, 1 up, 2 down - The prevent_change_timer is trigger after a change,
    set prevent_change_timer to 0, to disable this.

detect_limit: number[0-255] - Black threshold for cropdetect.
    Smaller values will generally result in less cropping.
    See limit of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_round: number[2^n] -  The value which the width/height should be divisible by 2. Smaller values have better detection
    accuracy. If you have problems with other filters, you can try to set it to 4 or 16.
    See round of https://ffmpeg.org/ffmpeg-filters.html#cropdetect

detect_seconds: seconds - How long to gather cropdetect data.
    Increasing this may be desirable to allow cropdetect more time to collect data.

max_aspect_ratio: [21.6/9] or [2.4], [24.12/9] or [2.68] - this is used to prevent cropping over the aspect ratio specified,
    any good cropping find over this option, will be with small black bar.
]]
require "mp.msg"
require "mp.options"

local options = {
    mode = 4,
    periodic_timer = 0,
    start_delay = 0,
    -- crop behavior
    prevent_change_timer = 0,
    prevent_change_mode = 2,
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

if options.mode == 0 then
    mp.msg.info("mode = 0, disable script.")
    return
end

-- Forward declarations
local cleanup
-- Init variables
local label_prefix = mp.get_script_name()
local labels = {
    crop = string.format("%s-crop", label_prefix),
    cropdetect = string.format("%s-cropdetect", label_prefix)
}
-- option
local min_h
local height_pct_margin_up = options.height_pct_margin / (1 - options.height_pct_margin)
local detect_seconds_adjust = options.detect_seconds
local limit_max = options.detect_limit
local limit_adjust = options.detect_limit
local limit_adjust_by = 1
-- state
local timer = {}
local in_progress, paused, toggled, seeking, filter_missing
-- metadata
local meta, meta_stat = {}, {}
local entity = {"size_origin", "apply_current", "detect_current", "detect_last"}
local unit = {"w", "h", "x", "y"}
for k, v in pairs(entity) do
    meta[v] = {unit}
end

local function meta_copy(from, to)
    for k, v in pairs(unit) do
        to[v] = from[v]
    end
end

local function meta_stats(meta_curr, offset_y, debug)
    -- Store stats
    if not debug then
        local meta_whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta_curr.w, meta_curr.h, meta_curr.x, meta_curr.y)
        if not meta_stat[meta_whxy] then
            meta_stat[meta_whxy] = {unit}
            meta_stat[meta_whxy].count = 0
            meta_stat[meta_whxy].offset_y = offset_y
            meta_copy(meta_curr, meta_stat[meta_whxy])
        end
        meta_stat[meta_whxy].count = meta_stat[meta_whxy].count + 1
    end
    -- Offset Majority
    local offset_y_count = {}
    local majority_offset_y
    for k, k1 in pairs(meta_stat) do
        local name_offset = string.format("%d", meta_stat[k].offset_y)
        if not offset_y_count[name_offset] then
            offset_y_count[name_offset] = 0
        end
        offset_y_count[name_offset] = offset_y_count[name_offset] + meta_stat[k].count
    end
    local majority_offset_y_count = 0
    for k, k1 in pairs(offset_y_count) do
        if offset_y_count[k] > majority_offset_y_count then
            majority_offset_y = k
            majority_offset_y_count = offset_y_count[k]
        end
    end
    -- Debug
    if debug and majority_offset_y then
        mp.msg.info("Meta Stats:")
        mp.msg.info(string.format("Offset majority is %d", majority_offset_y))
        for k, k1 in pairs(meta_stat) do
            if type(k) ~= "table" then
                mp.msg.info(string.format("%s offset_y=%s count=%s", k, meta_stat[k].offset_y, meta_stat[k].count))
            end
        end
        return
    end
    return tonumber(majority_offset_y)
end

local function init_size()
    local width = mp.get_property_native("width")
    local height = mp.get_property_native("height")
    meta.size_origin = {
        w = width,
        h = height,
        x = 0,
        y = 0
    }
    min_h = math.floor(meta.size_origin.w / options.max_aspect_ratio)
    if min_h % 2 ~= 0 then
        min_h = min_h + 1
    end
    meta_copy(meta.size_origin, meta.apply_current)
end

local function is_filter_present(label)
    local filters = mp.get_property_native("vf")
    for index, filter in pairs(filters) do
        if filter["label"] == label then
            return true
        end
    end
    return false
end

local function is_enough_time(seconds)
    local time_needed = seconds + 5
    local playtime_remaining = mp.get_property_native("playtime-remaining")
    if playtime_remaining and time_needed > playtime_remaining then
        mp.msg.warn("Not enough time for autocrop.")
        return false
    end
    return true
end

local function is_cropable()
    local vid = mp.get_property_native("vid")
    local is_album = vid and mp.get_property_native(string.format("track-list/%s/albumart", vid)) or false
    return vid and not is_album
end

local function insert_crop_filter()
    local insert_crop_filter_command =
        mp.command(string.format("no-osd vf pre @%s:lavfi-cropdetect=limit=%d/255:round=%d:reset=0", labels.cropdetect, limit_adjust, options.detect_round))
    if not insert_crop_filter_command then
        mp.msg.error("Does vf=help as #1 line in mvp.conf return libavfilter list with crop/cropdetect in log?")
        filter_missing = true
        cleanup()
        return false
    end
    return true
end

local function remove_filter(label)
    if is_filter_present(label) then
        mp.command(string.format("no-osd vf remove @%s", label))
    end
end

local function collect_metadata()
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

local function auto_crop()
    -- Pause timer
    in_progress = true
    if timer.periodic_timer then
        timer.periodic_timer:stop()
    end

    if options.mode % 2 == 1 and toggled == nil then
        toggled = true
        in_progress = false
        return
    end

    -- Verify if there is enough time to detect crop.
    local time_needed = detect_seconds_adjust
    if not is_enough_time(time_needed) then
        in_progress = false
        return
    end

    if not insert_crop_filter() then
        return
    end

    -- Wait to gather data.
    timer.crop_detect =
        mp.add_timeout(
        time_needed,
        function()
            if collect_metadata() and not paused and not toggled then
                if options.fixed_width then
                    meta.detect_current.w = meta.size_origin.w
                    meta.detect_current.x = meta.size_origin.x
                end

                local symmetric_x = meta.detect_current.x == (meta.size_origin.w - meta.detect_current.w) / 2
                local symmetric_y = meta.detect_current.y == (meta.size_origin.h - meta.detect_current.h) / 2
                local in_margin_y =
                    meta.detect_current.y >= (meta.size_origin.h - meta.detect_current.h - options.height_pxl_margin) / 2 and
                    meta.detect_current.y <= (meta.size_origin.h - meta.detect_current.h + options.height_pxl_margin) / 2
                local bigger_than_min_h = meta.detect_current.h >= min_h

                local majority_offset_y, current_offset_y, return_offset_y
                if in_margin_y and bigger_than_min_h then
                    current_offset_y = (meta.size_origin.h - meta.detect_current.h) / 2 - meta.detect_current.y
                    -- Store valid cropping meta and return offset majority
                    return_offset_y = meta_stats(meta.detect_current, current_offset_y)
                    majority_offset_y = current_offset_y == return_offset_y
                end

                -- crop with black bar if over max_aspect_ratio
                --[[ if in_margin_y and not bigger_than_min_h then
                    meta.detect_current.h = min_h
                    meta.detect_current.y = (meta.size_origin.h - meta.detect_current.h) / 2 + return_offset_y
                    bigger_than_min_h = true
                end ]]

                local not_already_apply = meta.detect_current.h ~= meta.apply_current.h or meta.detect_current.w ~= meta.apply_current.w
                local pxl_change_h =
                    meta.detect_current.h >= meta.apply_current.h - options.height_pxl_margin and meta.detect_current.h <= meta.apply_current.h + options.height_pxl_margin
                local pct_change_h =
                    meta.detect_current.h >= meta.apply_current.h - meta.apply_current.h * options.height_pct_margin and
                    meta.detect_current.h <= meta.apply_current.h + meta.apply_current.h * height_pct_margin_up
                local detect_confirmation = meta.detect_current.h == meta.detect_last.h

                -- Auto adjust black threshold and detect_seconds
                local detect_size_origin = meta.detect_current.h == meta.size_origin.h
                if in_margin_y then
                    if limit_adjust < limit_max then
                        if detect_size_origin then
                            if limit_adjust + limit_adjust_by * 2 <= limit_max then
                                limit_adjust = limit_adjust + limit_adjust_by * 2
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
                local crop_filter = not_already_apply and symmetric_x and majority_offset_y and (pxl_change_h or not pct_change_h) and bigger_than_min_h and detect_confirmation
                if crop_filter then
                    -- Apply cropping.
                    if not timer.prevent_change or not timer.prevent_change:is_enabled() then
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
                        -- Prevent upcomming change if a timer is defined
                        if options.prevent_change_timer > 0 then
                            if
                                options.prevent_change_mode == 1 and meta.detect_current.h > meta.apply_current.h or
                                    options.prevent_change_mode == 2 and meta.detect_current.h < meta.apply_current.h or
                                    options.prevent_change_mode == 0
                             then
                                timer.prevent_change =
                                    mp.add_timeout(
                                    options.prevent_change_timer,
                                    function()
                                    end
                                )
                            end
                        end
                        -- Save values to compare later.
                        meta_copy(meta.detect_current, meta.apply_current)
                    end
                    if options.mode < 3 then
                        in_progress = false
                        return
                    end
                end
                meta_copy(meta.detect_current, meta.detect_last)
            end
            -- Resume timer
            in_progress = false
            if timer.periodic_timer and not paused and not toggled then
                timer.periodic_timer:resume()
            end
        end
    )
end

function cleanup()
    mp.msg.info("Cleanup.")
    -- Kill all timers.
    for index, value in pairs(timer) do
        if timer[index]:is_enabled() then
            timer[index]:kill()
        end
    end
    -- Remove all timers.
    timer = {}
    -- Remove all existing filters.
    for key, value in pairs(labels) do
        remove_filter(value)
    end
    -- Reset some values
    meta_stat = {}
    meta.size_origin = {}
    limit_adjust = options.detect_limit
end

local function seek(name)
    mp.msg.info(string.format("Stop by %s event.", name))
    meta_stats(_, _, true)
    if timer.periodic_timer and timer.periodic_timer:is_enabled() then
        timer.periodic_timer:kill()
        if timer.crop_detect and timer.crop_detect:is_enabled() then
            timer.crop_detect:kill()
        end
    end
end

local function seek_event()
    seeking = true
end

local function resume(name)
    if timer.periodic_timer and not timer.periodic_timer:is_enabled() and not in_progress then
        timer.periodic_timer:resume()
        mp.msg.info(string.format("Resumed by %s event.", name))
    end
    local playback_time = mp.get_property_native("playback-time")
    if timer.start_delay and timer.start_delay:is_enabled() and playback_time > options.start_delay then
        timer.start_delay.timeout = 0
        timer.start_delay:kill()
        timer.start_delay:resume()
    end
end

local function resume_event()
    seeking = false
end

local function on_toggle()
    if filter_missing then
        mp.osd_message("Libavfilter cropdetect missing", 3)
        return
    end
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

local function pause(_, bool)
    if options.mode > 2 then
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

local function on_start()
    if not is_cropable() then
        mp.msg.warn("Only works for videos.")
        return
    end

    init_size()

    local start_delay
    if options.mode ~= 2 then
        start_delay = 0
    else
        start_delay = options.start_delay
    end

    timer.start_delay =
        mp.add_timeout(
        start_delay,
        function()
            local time_needed = options.periodic_timer
            timer.periodic_timer = mp.add_periodic_timer(time_needed, auto_crop)
        end
    )
end

mp.register_event("seek", seek_event)
mp.register_event("playback-restart", resume_event)
mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.observe_property("pause", "bool", pause)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
