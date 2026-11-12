# MacCam

**Full control of your USB webcam on macOS.** It was built for the Kreo Owl 4K Pro and works with any UVC webcam.

macOS has no settings panel for USB webcams, so cameras like the Kreo Owl 4K Pro stay on whatever automatic settings they boot with. MacCam talks to the camera directly over USB (the UVC protocol) to unlock every control the hardware has. On top of that it adds a GPU "studio" pipeline: Center Stage-style auto framing, background blur, colour grading, and a virtual camera for Zoom, Meet, Teams and OBS.

## Features

### Camera tab: hardware controls (inside the camera)
These settings are applied by the camera itself, so **they work in every app**, including when you don't use MacCam's virtual camera.

| Group | Controls (only the ones your camera supports are shown) |
|---|---|
| Image | Brightness, Contrast (+ auto), Sharpness, Gamma |
| Color & White Balance | **Auto WB on/off, Color Temperature (K)**, WB red/blue gains, Saturation, Hue |
| Exposure & Light | **Exposure mode (manual / auto / priority), Exposure time**, Gain (ISO), Backlight compensation (WDR), Low-light frame-rate priority, Iris |
| Focus & Zoom | Auto focus on/off, Manual focus, Hardware zoom, In-camera digital zoom |
| Pan / Tilt / Roll | Hardware PTZ (on cameras that have it) |
| Advanced | **Anti-flicker 50/60 Hz** (use 50 Hz in India/Europe/Asia to stop LED banding), Privacy shutter |

* Live values: while a setting is on auto (for example auto white balance), the slider shows what the camera is choosing.
* **Settings survive replugging.** Most webcams forget their settings on power loss. MacCam re-applies them when the camera reconnects.
* Reset any control (or all of them) to the camera's factory default.

### Studio tab: software pipeline (GPU, Core Image + Vision)
* **Auto Framing ("Center Stage")**: follows your face, upper body, or everyone in view by cropping the 4K sensor. A 4K sensor gives up to 2× zoom into a 1080p output with no quality loss. Tightness, motion speed and max zoom are adjustable, with a dead zone so the shot doesn't wobble. When nobody is in view it eases back out to the wide shot.
* Manual digital zoom and pan/tilt for cameras without hardware PTZ.
* **Background**: blur, studio colour, or your own image (Apple Vision person segmentation).
* **Colour & tone**: warmth/tint, exposure, contrast, brightness, highlights, shadows, saturation, vibrance.
* **Detail**: sharpen, noise reduction, vignette.
* **Looks**: Cinematic, Warm Film, Chrome, Fade, Instant, Mono, Noir and more, each with an intensity slider.
* Mirror / upside-down, output 720p, 1080p, 1440p or 4K.
* Live RGB histogram, rule-of-thirds grid, photo snapshots (PNG) and video recording (H.264/HEVC).

### Presets
Save all hardware and studio settings under a name, apply them in one click, and import or export them as JSON. Starter looks are included.

### Virtual camera
"MacCam Virtual Camera" appears in Zoom, Google Meet, Teams, OBS, FaceTime and other apps, carrying everything from the Studio tab. Built with a Core Media I/O camera extension.

### Menu bar
MacCam keeps running in the menu bar when you close the window, with quick toggles for framing, blur, mirror, presets and the virtual camera.

## Requirements
* **macOS 26 or later**, on Apple Silicon or Intel (it uses the macOS 26 Liquid Glass interface)
* To build it yourself: Xcode 26 or later
* A UVC webcam (virtually all USB webcams, including the Kreo Owl 4K Pro)

## Install

### Option A: download the build from CI (no Xcode needed)
1. Open the repository's **Actions** tab → latest **Build** run → download **MacCam-app**.
2. Unzip it and move `MacCam.app` to `/Applications`.
3. The build isn't notarized, so clear the quarantine flag once:
   ```bash
   xattr -dr com.apple.quarantine /Applications/MacCam.app
   ```
4. Open it and allow camera access.

This build includes everything except the virtual camera (see Option C).

### Option B: build it yourself with SwiftPM
Needs Xcode 26 or the matching Command Line Tools.
```bash
./scripts/build-app.sh
```
```bash
open dist/MacCam.app
```

### Option C: full build with the virtual camera (Xcode)
macOS only loads camera extensions signed by a registered developer, so you need an **Apple Developer Program** membership.
```bash
brew install xcodegen
```
```bash
xcodegen generate && open MacCam.xcodeproj
```
1. In `project.yml` (or Xcode → Signing & Capabilities for both targets), set your `DEVELOPMENT_TEAM`. You can also change `APP_BUNDLE_ID`.
2. Build the **MacCam** scheme, then copy the built `MacCam.app` to **/Applications**. System extensions only activate from there.
3. In MacCam go to **Studio → Virtual Camera → Install Virtual Camera**, then approve it in System Settings → General → Login Items & Extensions → Camera Extensions (or Privacy & Security).
4. Turn on **Send to Virtual Camera** and choose "MacCam Virtual Camera" in your meeting app.

## Tips for the Kreo Owl 4K Pro
* Choose the **3840×2160 MJPEG** format in the toolbar. It gives auto framing the most pixels to crop from.
* Set **Anti-Flicker to 50 Hz** if you're in India (60 Hz in the Americas).
* For stable skin tones on stream, turn **Auto White Balance off** and set the colour temperature manually (about 4000–4500 K under warm room lights, 5500–6500 K in daylight).
* If the image is too dark at night, raise **Gain** or use the **Low-Light Rescue** look before slowing the shutter. A longer exposure causes motion blur.
* If a control seems missing, use **Info → Probe All Controls**. Some cameras under-report what they support.

## How it works
```
USB webcam ──UVC control requests (IOKit)──▶ hardware settings (Camera tab)
    │
    └─ video (AVFoundation) ─▶ Vision (faces / bodies / person mask)
                              ─▶ Core Image on the GPU: background → framing crop → colour → look
                              ─▶ preview (Metal) · recorder · virtual-camera sink ─▶ CMIO extension ─▶ Zoom/Meet/OBS
```

| Path | What |
|---|---|
| `Sources/MacCam/UVC/` | USB descriptor parsing, UVC control catalogue, IOKit control transfers, control store |
| `Sources/MacCam/Capture/` | AVCaptureSession, device and format selection |
| `Sources/MacCam/Processing/` | Frame processor, auto framer, Vision analyzer |
| `Sources/MacCam/Output/` | Recorder, virtual camera sink, system-extension installer |
| `Sources/MacCam/UI/` | SwiftUI interface |
| `CameraExtension/` | Core Media I/O camera extension (virtual camera) |
| `Tests/ParserCheck/` | Stand-alone checks for descriptor parsing and value encoding |

## Troubleshooting
* **"No hardware controls found"**: the camera must be plugged in directly or through a data-capable hub. Built-in FaceTime and Continuity cameras don't support UVC controls, but the Studio tab still works with them.
* **A control is greyed out with an AUTO badge**: turn off its auto mode first (for example *Auto White Balance* before *Color Temperature*, or *Exposure Mode → Manual* before *Exposure Time*).
* **The virtual camera shows "Open the MacCam app"**: MacCam has to be running with *Send to Virtual Camera* on.
