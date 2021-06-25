# dynamic-crop.lua

Base on https://github.com/mpv-player/mpv/blob/master/TOOLS/lua/autocrop.lua.

Script to "cropping" dynamically, hard-coded black bars detected with lavfi-cropdetect filter for Ultra Wide Screen (21:9) or any screen different from 16:9 (Phone/old TV).

## Status

It's now really stable, but can probably be improved for more edge case.

## Usage

Save `dynamic-crop.lua` in `~/.config/.mpv/scripts/` (Linux/macOS) or `%AppData%\mpv\scripts\` (Windows).

Or edit your `mpv.conf` file to add `script=<custom path to the script>`, use absolute path and don't add it if you already put it in directory `scripts`:
```
## Example
# Linux/macOS:
script=/home/<username>/<any custom path you choose>/dynamic-crop.lua
# Windows:
script=C:\Users\<username>\<any custom path you choose>\dynamic-crop.lua
# Android mpv-android:
script=/storage/emulated/0/<any custom path you choose>/dynamic-crop.lua
```

## Features

- 5 mode available: 0 disable, 1 on-demand, 2 single-start, 3 auto-manual, 4 auto-start.
- New cropping meta are validate with a known list of aspect ratio and `new_known_ratio_timer`, and without the list with `new_fallback_timer`.
- Correction of random metadata to an already trusted one, this mostly help to get a fast aspect ratio change with dark/ambiguous scene.
- Support asymmetric offset (Re-center video).
- Auto adjust black threshold (cropdetect=limit).
- Handle seeking/loading and speed from 0.5 to 100.
- Option to prevent aspect ratio change during a certain time (in scene changing back and forth in less than X seconds).
- Allow deviation of continuous data required to approve new meta.

## Shortcut 

SHIFT+C do:

The first press maintains the cropping and disables the script, a second pressure is necessary to restart the script. 
- Mode = 1-2, single cropping on demand, stays active until a valid cropping is apply.
- Mode = 3-4, enable / disable continuous cropping.

## To-Do

- Documentation.

## Troubleshooting

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `Available libavfilter filters:`.

Also make sure mpv option `hwdec=` is `no`(default) or any `*-copy` ([doc](https://mpv.io/manual/stable/#options-hwdec)), or the video filters won't work.

Collect the log by adding to mpv.conf, `log-file=C:\Users\<username>\AppData\Roaming\mpv\mpv.log -- Or any path you can find easily` 

## Download on phone

Use the Desktop mode with a navigator on this page to access the button `Code > Download Zip`.
Or transfer it from a computer.
