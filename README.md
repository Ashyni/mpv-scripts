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

-   4 modes available: 0 disable, 1 on-demand, 2 one-shot, 3 dynamic-manual, 4 dynamic-auto.
-   Support hardware decoding with *-copy variant only (read_ahead_mode=1/2 required ffmpeg patch to avoid color issue)
-   Correction with trusted metadata for fast change in dark/ambiguous scene.
-   Support asymmetric offset (Re-center video).
-   Auto adjust black threshold (cropdetect=limit).
-   Ability to prevent aspect ratio change during a certain time.
-   Allows the segmentation of normally continuous data required to approve a new metadata.
-   Handle seeking/loading and any change of speed handled by MPV.
-   Read ahead cropdetect filter metadata, useful for videos with multiple aspect ratio changes (require ffmpeg master/6+).

## Shortcut

SHIFT+C do:

Cycle between ENABLE / DISABLE_WITH_CROP / DISABLE

## To-Do

-   Improve documentation.
-   Improve read_ahead.

## Troubleshooting

To collect the log, add to mpv.conf, `log-file=<any path you can find easily>`

If the script doesn't work, make sure mpv is build with the libavfilter `crop` and `cropdetect` by starting mpv with `./mpv --vf=help` or by adding at the #1 line in mpv.conf `vf=help` and check the log for `Available libavfilter filters:`.

Make sure mpv option `hwdec=` is `no`(default) or any `*-copy` ([doc](https://mpv.io/manual/stable/#options-hwdec)), otherwise the script will fail.

Performance issue with mpv client or specific gpu-api (solved with [patch](https://github.com/FFmpeg/FFmpeg/commit/69c060bea21d3b4ce63b5fff40d37e98c70ab88f)):  
-   mpv.conf: Try different value for `gpu-api=` ([doc](https://mpv.io/manual/master/#options-gpu-api)).  
-   Script settings: Increase option `limit_timer` to slow down limit change, main source of performance issue depending on gpu-api used.  
-   JellyfinMediaPlayer settings: Try with `UseOpenGL`.

## Download on phone

Use the Desktop mode with a navigator on this page to access the button `Code > Download Zip`.  
Or transfer it from a computer or any other device.
