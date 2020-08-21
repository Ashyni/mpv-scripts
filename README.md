# mpv-scripts

## autocrop.lua
<br/>
Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.
<br/>
Script to automaticly crop top/bottom black bar on Ultra Wide Screen (21:9).

### Features:
Periodic or Single scan/crop.
Shortcut SHIFT+C do:
  - if auto=false, crop on demand.
  - if auto=true, remove last crop and stay disable until key is press again.
Prevent crop bigger than option max_aspect_ratio.
Prevent asymmetric crop with a few pixel tolerance.
Option to prevent small width and/or height change.
Detect dark scene and adjust detect_limit.
Auto pause the script when seeking.
