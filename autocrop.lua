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
]]
require "mp.msg"
require "mp.options"

local options = {
    mode = 4,
    start_delay = 0,
    -- crop behavior
    prevent_change_timer = 0,
    prevent_change_mode = 2,
    new_offset_timer = 10,
    new_aspect_ratio_timer = 3,
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
local new_aspect_ratio_timer = math.ceil(options.new_aspect_ratio_timer / (options.detect_seconds + .05))
local detect_seconds = options.detect_seconds
local limit_current = options.detect_limit
local limit_last = options.detect_limit
local limit_step = 2
-- state
local timer = {}
local in_progress, paused, toggled, seeking, filter_missing
-- metadata
local source, applied, stats, trusted_offset, tmp = {}, {}, {}, {}, {}
local unit = {"w", "h", "x", "y", "whxy"}

local function is_trusted_offset(offset, axis)
    for _, v in pairs(trusted_offset[axis]) do
        if offset == v then
            return true
        end
    end
    return false
end

local function copy_meta(from, to)
    for _, v in pairs(unit) do
        to[v] = from[v]
    end
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
    if not is_filter_present(labels.cropdetect) then
        -- "vf pre" use source size and "vf add" use crop size as comparison for offset math.
        local insert_crop_filter_command =
            mp.command(string.format("no-osd vf pre @%s:lavfi-cropdetect=limit=%.3f/255:round=%d:reset=0", labels.cropdetect, limit_current, options.detect_round))
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

local function tmp_stats(meta, stat_)
    if not stat_ or stat_ == "whxy" then
        meta.whxy = string.format("w=%s:h=%s:x=%s:y=%s", meta.w, meta.h, meta.x, meta.y)
    end
    if not stat_ then
        tmp.detect_source = meta.whxy == source.whxy
        tmp.already_apply = meta.whxy == applied.whxy
        tmp.offset_x = (source.w - meta.w) / 2 - meta.x
        tmp.offset_y = (source.h - meta.h) / 2 - meta.y
    end
end

local function collect_metadata()
    local cropdetect_metadata = mp.get_property_native(string.format("vf-metadata/%s", labels.cropdetect))
    if cropdetect_metadata and cropdetect_metadata["lavfi.cropdetect.w"] then
        -- Remove filter to reset detection.
        remove_filter(labels.cropdetect)
        -- Make metadata usable.
        tmp = {
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
    local time_needed = detect_seconds
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
            if collect_metadata() and not (paused or toggled or seeking) then
                tmp_stats(tmp)
                local invalid_h = tmp.h < 0
                local in_margin_y = tmp.y >= 0 and tmp.y <= source.h - tmp.h
                local bottom_limit_reach = tmp.detect_source and limit_current < limit_last
                local confirmation, detect_source

                -- Debug cropdetect meta
                --mp.msg.info(string.format("detect_curr=w=%s:h=%s:x=%s:y=%s offsetY:%s limit:%s limit_step:%s", tmp.w, tmp.h, tmp.x, tmp.y, tmp.offset_y, limit_current, limit_step))
                -- Store cropping meta, find trusted offset, and correct to closest meta if neccessary.
                if in_margin_y and not bottom_limit_reach then
                    -- Store stats
                    local margin_correct = math.floor(tmp.h * 0.01)
                    if not stats[tmp.whxy] then
                        stats[tmp.whxy] = {}
                        stats[tmp.whxy].counter = {detect = 0, last_seen = 0, correct = 0, applied = 0}
                        stats[tmp.whxy].offset_y = tmp.offset_y
                        copy_meta(tmp, stats[tmp.whxy])
                    end
                    stats[tmp.whxy].counter.detect = stats[tmp.whxy].counter.detect + 1
                    if stats[tmp.whxy].counter.last_seen < 0 then
                        stats[tmp.whxy].counter.last_seen = 0
                    end
                    stats[tmp.whxy].counter.last_seen = stats[tmp.whxy].counter.last_seen + 1
                    local closest = stats[tmp.whxy]
                    -- Add Trusted Offset
                    if not is_trusted_offset(tmp.offset_y, "y") then
                        if not timer.new_offset_y then
                            timer.new_offset_y =
                                mp.add_timeout(
                                options.new_offset_timer,
                                function()
                                end
                            )
                        elseif stats[tmp.whxy].counter.last_seen > 1 and not timer.new_offset_y:is_enabled() then
                            table.insert(trusted_offset.y, stats[tmp.whxy].offset_y)
                        end
                    end
                    if timer.new_offset_y and stats[tmp.whxy].counter.last_seen == 1 then
                        timer.new_offset_y:kill()
                        timer.new_offset_y:resume()
                    end

                    for k in pairs(stats) do
                        if k ~= tmp.whxy then
                            if stats[k].counter.last_seen > 0 then
                                stats[k].counter.last_seen = 0
                            end
                            stats[k].counter.last_seen = stats[k].counter.last_seen - 1
                        end
                        -- Closest metadata
                        local meta_in_margin_h = tmp.h >= stats[k].h - margin_correct and tmp.h <= stats[k].h + margin_correct and stats[k].counter.detect > closest.counter.detect
                        if meta_in_margin_h then
                            closest = stats[k]
                            closest.whxy = k
                        end
                    end
                    -- Maybe add an option to disable correction
                    if closest and is_trusted_offset(closest.offset_y, "y") and closest.whxy ~= tmp.whxy then
                        --mp.msg.info(string.format("Correct %s to %s.", tmp.whxy, closest.whxy))
                        copy_meta(closest, tmp)
                        tmp_stats(tmp)
                        if stats[tmp.whxy].counter.correct > 2 or tmp.already_apply then
                            stats[tmp.whxy].counter.correct = 0
                        else
                            stats[tmp.whxy].counter.correct = stats[tmp.whxy].counter.correct + 1
                        end
                    end
                    confirmation =
                        not tmp.detect_source and
                        (stats[tmp.whxy].counter.applied > 0 and math.max(0, stats[tmp.whxy].counter.last_seen) + stats[tmp.whxy].counter.correct > 1 or
                            stats[tmp.whxy].counter.last_seen > math.floor(source.h / tmp.h * new_aspect_ratio_timer + .5))
                    detect_source = tmp.detect_source and (limit_current > limit_last or stats[tmp.whxy].counter.last_seen > 1)
                    last_seen = stats[tmp.whxy].counter.last_seen > 1
                end

                local trusted_offset_y = is_trusted_offset(tmp.offset_y, "y")
                local trusted_offset_x = is_trusted_offset(tmp.offset_x, "x")
                -- Auto adjust black threshold and detect_seconds
                limit_last = limit_current
                if tmp.detect_source and limit_current < options.detect_limit then
                    if limit_current + limit_step * 2 <= options.detect_limit then
                        limit_current = limit_current + limit_step * 2
                        if limit_step > .125 then
                            limit_step = limit_step / 2
                        end
                    else
                        limit_current = options.detect_limit
                    end
                    detect_seconds = .1
                elseif (last_seen or trusted_offset_y) and not invalid_h then
                    limit_step = 2
                    limit_current = math.ceil(limit_current)
                    detect_seconds = options.detect_seconds
                elseif limit_current > 0 then
                    if limit_current - limit_step >= 0 then
                        limit_current = limit_current - limit_step
                    else
                        limit_current = 0
                    end
                    detect_seconds = .1
                end

                -- Crop Filter:
                local crop_filter = not invalid_h and not tmp.already_apply and trusted_offset_x and trusted_offset_y and (confirmation or detect_source)
                if crop_filter then
                    -- Applied cropping.
                    stats[tmp.whxy].counter.applied = stats[tmp.whxy].counter.applied + 1
                    if not timer.prevent_change or not timer.prevent_change:is_enabled() then
                        mp.command(string.format("no-osd vf pre @%s:lavfi-crop=%s", labels.crop, tmp.whxy))
                        -- Prevent upcomming change if a timer is defined
                        if options.prevent_change_timer > 0 then
                            if options.prevent_change_mode == 1 and tmp.h > applied.h or options.prevent_change_mode == 2 and tmp.h < applied.h or options.prevent_change_mode == 0 then
                                timer.prevent_change =
                                    mp.add_timeout(
                                    options.prevent_change_timer,
                                    function()
                                    end
                                )
                            end
                        end
                        copy_meta(tmp, applied)
                    end
                    if options.mode < 3 then
                        in_progress = false
                        return
                    end
                end

                -- Cleanup Stats
                for k in pairs(stats) do
                    if stats[k].counter.detect < 20 and stats[k].counter.last_seen < 0 and stats[k].counter.applied < 1 then
                        -- Remove mistrusted offset, if any, except 0.
                        for k1, v1 in pairs(trusted_offset.y) do
                            if stats[k].offset_y == v1 and stats[k].offset_y ~= 0 then
                                table.remove(trusted_offset.y, k1)
                                break
                            end
                        end
                        -- Remove small detect, that was never applied.
                        stats[k] = nil
                    end
                end
                tmp = {}
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
    for index in pairs(timer) do
        if timer[index]:is_enabled() then
            timer[index]:kill()
        end
    end
    -- Remove all timers.
    timer = {}
    -- Remove all existing filters.
    for _, value in pairs(labels) do
        remove_filter(value)
    end
    -- Reset some values
    stats, tmp = {}, {}
    limit_current = options.detect_limit
end

local function init_size()
    local width = mp.get_property_native("width")
    local height = mp.get_property_native("height")
    source = {
        w = width,
        h = height,
        x = 0,
        y = 0
    }
    tmp_stats(source, "whxy")
    copy_meta(source, applied)
    stats[source.whxy] = {}
    stats[source.whxy].counter = {detect = 0, last_seen = 0, correct = 0, applied = 1}
    stats[source.whxy].offset_y = 0
    copy_meta(source, stats[source.whxy])
    trusted_offset.y = {0}
    trusted_offset.x = {0}
end

local function seek(name)
    mp.msg.info(string.format("Stop by %s event.", name))
    if timer.periodic_timer and timer.periodic_timer:is_enabled() then
        timer.periodic_timer:kill()
        if timer.crop_detect then
            timer.crop_detect = nil
        end
        if timer.new_offset_y then
            timer.new_offset_y:stop()
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
    if timer.new_offset_y then
        timer.new_offset_y:resume()
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
        copy_meta(source, applied)
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
            -- Debug Stats
            if stats then
                mp.msg.info("Meta Stats:")
                local read_maj_offset_y = ""
                for _, v in pairs(trusted_offset.y) do
                    read_maj_offset_y = read_maj_offset_y .. v .. " "
                end
                mp.msg.info(string.format("Trusted Offset: Y:%s", read_maj_offset_y))
                for k in pairs(stats) do
                    mp.msg.info(
                        string.format(
                            "%s offset_y=%s counter(detect=%s last_seen=%s applied=%s)",
                            k,
                            stats[k].offset_y,
                            stats[k].counter.detect,
                            stats[k].counter.last_seen,
                            stats[k].counter.applied
                        )
                    )
                end
            end
        else
            paused = false
            if not toggled then
                resume("unpause")
            end
        end
    end
end

local function on_start()
    mp.msg.info("File loaded.")
    if not is_cropable() then
        mp.msg.warn("Exit, only works for videos.")
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
            timer.periodic_timer = mp.add_periodic_timer(0, auto_crop)
        end
    )
end

mp.register_event("seek", seek_event)
mp.register_event("playback-restart", resume_event)
mp.observe_property("pause", "bool", pause)
mp.add_key_binding("C", "toggle_crop", on_toggle)
mp.register_event("end-file", cleanup)
mp.register_event("file-loaded", on_start)
