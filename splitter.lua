require "mp.msg"
require "mp.options"

local options = {
    enable = true,
    audio = "",
    subtitles = ""
}
read_options(options)

function on_start()
end

mp.register_event("file-loaded", on_start)