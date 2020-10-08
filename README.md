# mpv-scripts

## autocrop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to automatically crop top/bottom black bar on Ultra Wide Screen (21:9) or any wider screen (phone).

### Features

- Periodic or Single scan/crop.
- Prevent crop bigger than option max_aspect_ratio.
- Prevent asymmetric crop.
- Auto adjust black threshold.
- Auto pause the script when seeking/loading.

### To-Do

- Add width filter, for now it's recommended to keep `fixed_width = true`.
- Add timer to prevent too much change in a row with the preference of keeping up or down.
- Documentation

### OS

 - Windows: OK (mpv or mpv-shim)
 - Linux:   Not tested
 - Android: OK ([mpv-android](https://github.com/mpv-android/mpv-android/commit/348e9511f51238c00a3aca3c3b2ae4d4b661f7f5))
 - Mac:     Not tested
 - iOS:     Not tested

### Shortcut 

SHIFT+C do:

If auto=false, crop on demand.
If auto=true, remove last crop and stay disable until key is press again.

### Troubleshooting

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `V/mpv     : [cplayer:info] Available libavfilter filters:`.