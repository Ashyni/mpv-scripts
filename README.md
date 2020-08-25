# mpv-scripts

## autocrop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to automatically crop top/bottom black bar on Ultra Wide Screen (21:9).

### Features

- Periodic or Single scan/crop.
- Option to prevent small width and/or height change.
- Prevent crop bigger than option max_aspect_ratio.
- Prevent asymmetric crop.
- Detect dark scene and auto adjust detect_limit.
- Auto pause the script when seeking/loading.

### Shortcut 

SHIFT+C do:

If auto=false, crop on demand.

If auto=true, remove last crop and stay disable until key is press again.
