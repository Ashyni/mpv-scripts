# mpv-scripts

## autocrop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to automatically "crop" in real time top/bottom black bar on Ultra Wide Screen (21:9) or any wider screen (phone).

### Status

Starting to get really good.
Still work in progress, some regressions can occur during process.

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

- 5 mode available: 0 disable, 1 on-demand, 2 single-start, 3 auto-manual, 4 auto-start.
- Support Asymmetric offset on Y axis, based on repeated value, setup by option `new_offset_timer`.
- New aspect ratio are validate, based on repeated value, setup by option `new_aspect_ratio_timer`.
- Fast change of already trusted metadata, after the first validation based `new_aspect_ratio_timer`.
- Correction of value to prevent unwanted small change and helped in dark scene, its based on closest height metadata find in majority (fixed value of 1% for now).
- Auto adjust black threshold.
- Auto pause the script when seeking/loading.

### To-Do

- Add width_mode, for now only cropping with an offset_x 0 can occurs and depend on the options `new_aspect_ratio_timer`.
- Add strict_mode, to allow only new aspect ratio of known values (1.78, 1.88, 2, 2.4 , 2.68, ...).
- Documentation.

### OS

 - Windows: OK ([mpv](https://mpv.io/) or [mpv-shim](https://github.com/iwalton3/jellyfin-mpv-shim))
 - Linux:   Not tested
 - Android: OK ([mpv-android](https://github.com/mpv-android/mpv-android))
 - Mac:     Not tested
 - iOS:     Not tested

### Shortcut 

SHIFT+C do:

- If mode = 1-2, single cropping on demand, stays active until a valid cropping is apply.
- If mode = 3-4, enable / disable continuous cropping.

### Troubleshooting

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `mpv : [cplayer:info] Available libavfilter filters:`.

#### Download on phone

Use the Desktop mode with a navigator on this page to access the button `Code > Download Zip`.