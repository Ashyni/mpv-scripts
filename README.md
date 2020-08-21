# mpv-scripts

## autocrop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to automaticly crop top/bottom black bar on Ultra Wide Screen (21:9).

### Features

Periodic or Single scan/crop.

Prevent crop bigger than option max_aspect_ratio.

Prevent asymmetric crop with a few pixel tolerance.

Option to prevent small width and/or height change.

Detect dark scene and adjust detect_limit.

Auto pause the script when seeking.

## Shortcut 

SHIFT+C do:

If auto=false, crop on demand.

If auto=true, remove last crop and stay disable until key is press again.
