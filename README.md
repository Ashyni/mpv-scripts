# autocrop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to automatically "cropping"  hard coded black bars in real time on Ultra Wide Screen (21:9) or any wider screen (phone).

## Status

It's now really stable, but can probably be improved for more edge case.

## Usage

Save `autocrop.lua` in `~/.config/.mpv/scripts/` (Linux/macOS) or `%AppData%\mpv\scripts\` (Windows) or `/storage/emulated/0/` (Android SD card). 
Edit your `mpv.conf` file to add `script=<path to the script>`, eg:
```
#Windows mpv-shim:
script=C:\Users\<username>\AppData\Roaming\jellyfin-mpv-shim\scripts\autocrop.lua
#Android mpv-android:
script=/storage/emulated/0/mpv/autocrop.lua
```

## Features

- 5 mode available: 0 disable, 1 on-demand, 2 single-start, 3 auto-manual, 4 auto-start.
- Support Asymmetric offset.
- New cropping meta are validate with a known list of aspect ratio and `new_known_ratio_timer`, then without the list with `new_fallback_timer`.
- Correction of random metadata to an already trusted one, this mostly help to get a fast aspect ratio change with dark/ambiguous scene.
- Auto adjust black threshold.
- Auto pause the script when seeking/loading.
- Option to prevent change during a certain time (in scene changing back and forth in less than X seconds).

## To-Do

- Documentation.

## OS

 - Windows: OK ([mpv](https://mpv.io/) or [mpv-shim](https://github.com/jellyfin/jellyfin-desktop))
 - Linux:   Not tested
 - Android: OK ([mpv-android](https://github.com/mpv-android/mpv-android))
 - Mac:     Not tested
 - iOS:     Not tested

## Shortcut 

SHIFT+C do:

- If mode = 1-2, single cropping on demand, stays active until a valid cropping is apply.
- If mode = 3-4, enable / disable continuous cropping.

## Troubleshooting

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `Available libavfilter filters:`.

## Download on phone

Use the Desktop mode with a navigator on this page to access the button `Code > Download Zip`.
