# dynamic-crop.lua

Script to "cropping" dynamically, hard-coded black bars detected with lavfi-cropdetect filter for Ultra Wide Screen or any screen (Smartphone/Tablet).

## Status

It's now really stable, but can probably be improved to handle more case.

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

- 4 modes available: 0 disable, 1 on-demand, 2 one-shot, 3 dynamic-manual, 4 dynamic-auto.
- The new metadata are validated with a known list of aspect ratio that allows a faster timer (option `new_known_ratio_timer`) then without it, must be a longer timing to avoid unwanted cropping (option `new_fallback_timer`).
- Correction of random metadata to an already trusted one, this mostly help to get a fast aspect ratio change with dark/ambiguous scene.
- Support asymmetric offset (Re-center video).
- Auto adjust black threshold (cropdetect=limit, max is define by the option `detect_limit`).
- Ability to prevent aspect ratio change during a certain time (option `prevent_change_timer` and `prevent_change_mode`).
- Allows the segmentation of normally continuous data required to approve a new metadata (option `segmentation`).
- Handle seeking/loading and any change of speed handled by MPV.

## Shortcut 

SHIFT+C do:

The first press maintains the cropping and disables the script, a second pressure eliminates the cropping and a third pressure is necessary to restart the script. 
- Mode = 1-2, single cropping on demand, stays active until a valid cropping is apply.
- Mode = 3-4, enable / disable continuous cropping.

## To-Do

- Improve Documentation.
- Rework buffer to split fallback/offset validation and get more flexibility to turn off different timers.
- Improve auto limit stability, to reduce impact on some client.
- Find a way to work on data ahead to get perfect cropping timing (the dream).

## Troubleshooting

To collect the log, add to mpv.conf, `log-file=<any path you can find easily>`

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `Available libavfilter filters:`.

Also make sure mpv option `hwdec=` is `no`(default) or any `*-copy` ([doc](https://mpv.io/manual/stable/#options-hwdec)), or the video filters won't work.

Performance issue with Jellyfin Media Player/Qt client:  
JMP settings: Try with `UseOpenGL`  
Script settings: Increase option `detect_skip = 6` or `12`, check built-in doc

## Download on phone

Use the Desktop mode with a navigator on this page to access the button `Code > Download Zip`.  
Or transfer it from a computer or any other device.
