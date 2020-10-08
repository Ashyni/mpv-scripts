# mpv-scripts

## autocrop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to automatically "crop" top/bottom black bar on Ultra Wide Screen (21:9) or any wider screen (phone).

### Usage

Save `autocrop.lua` in `~/.config/.mpv/scripts/` (Linux/macOS) or `%AppData%\mpv\scripts\` (Windows) or `/storage/emulated/0/` (Android SD card). 
Edit your `mpv.conf` file to add `script=<path to the script>`, eg:
```
#Windows mpv-shim:
script=C:\Users\<username>\AppData\Roaming\jellyfin-mpv-shim\scripts\autocrop.lua
#Android mpv-android:
script=/storage/emulated/0/Download/autocrop.lua
```

### Features

- Periodic or Manual/Single "crop".
- Multiple filters to prevent unwanted "cropping".
- Auto adjust black threshold.
- Auto pause the script when seeking/loading.

### To-Do

- Add width filter, for now it's recommended to keep `fixed_width = true`.
- Add timer to prevent too much change in a row with the preference of keeping up or down.
- Improve manual/single "crop".
- Documentation.

### OS

 - Windows: OK ([mpv](https://github.com/mpv-player/mpv) or [mpv-shim](https://github.com/iwalton3/jellyfin-mpv-shim))
 - Linux:   Not tested
 - Android: OK ([mpv-android](https://github.com/mpv-android/mpv-android/commit/348e9511f51238c00a3aca3c3b2ae4d4b661f7f5))
 - Mac:     Not tested
 - iOS:     Not tested

### Shortcut 

SHIFT+C do:

If auto=false, "crop" on demand.
If auto=true, remove last "crop" and stay disable until key is press again.

### Troubleshooting

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `V/mpv     : [cplayer:info] Available libavfilter filters:`.