require "mp.msg"
require "mp.options"

local options = {
    enable = true,
    audio = "",
    subtitles = ""
}
read_options(options)

local function on_start()
end

mp.register_event("file-loaded", on_start)