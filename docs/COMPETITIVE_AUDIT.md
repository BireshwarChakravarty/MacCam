# Competitive audit

How Framelight compares with the leading webcam software (November 2026). Feature claims come from vendor pages, manuals and reviews (sources below). ✅ = has it, ➖ = partial, ❌ = doesn't have it.

| Feature | Camo | Elgato Camera Hub | Opal Composer | Insta360 Link Ctrl | OBSBOT Center | NVIDIA Broadcast | Logi Tune | UVC utilities¹ | **Framelight** |
|---|---|---|---|---|---|---|---|---|---|
| Full UVC hardware control (any webcam) | ➖ | own cams | own cams | own cams | own cams | ❌ | own cams | ✅ | ✅ |
| Re-apply settings on reconnect | – | ➖ save to camera | – | – | – | – | – | ✅ | ✅ |
| Per-app presets | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ CamDial Pro | ✅ |
| Hold settings against other apps | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ CamDial Pro | ✅ |
| Auto framing | ✅ | ❌ | ❌ | ✅ gimbal | ✅ gimbal | ✅ | ✅ RightSight | ❌ | ✅ smooth springs |
| Shot / position presets + hotkeys | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ➖ camctl | ✅ glide between shots |
| Gesture control | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ palm / peace sign |
| Vertical 9:16 output | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ | ✅ + 4:3, 1:1 |
| Face lighting correction | ✅ Spotlight | ❌ | ❌ | ❌ | ❌ | ✅ key light | ❌ | ❌ | ✅ Auto Light, Studio Light |
| Metering modes | ❌ | ✅ centre / average | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ face / centre / average |
| Skin-aware white balance | ❌ | ❌ | ➖ colour picker | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ skin tone line |
| Pick white point from image | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Built-in looks | ✅ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ 7, perceptual |
| Import .cube LUTs | ❌ | ✅ (2.0) | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Background blur / replace | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ halo-free, lens blur |
| Privacy blur | ✅ | ❌ | ❌ | ✅ privacy mode | ✅ privacy | ❌ | ❌ | ❌ | ✅ |
| Overlays / name tag | ✅ | ❌ | ➖ stickers | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ name tag |
| Video noise reduction | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ motion-adaptive temporal |
| Before / after compare | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ |
| Performance overlay | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ + `--benchmark` |
| Virtual camera | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ (needs Developer ID) |
| Eye contact correction | ❌ | ✅ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ needs a dedicated model |
| Whiteboard mode | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ planned |
| Audio in recordings | ✅ | – | – | – | ✅ | ✅ | – | – | ❌ planned |

¹ Webcam Settings, CamDial, CamControl, camctl, CameraController.

## What we took from each
- **CamDial**: per-app presets and holding settings against apps that reset them.
- **Insta360 / OBSBOT**: gesture control (open palm), shot presets on hotkeys, vertical output.
- **Elgato Camera Hub**: centre-weighted and average metering, `.cube` LUT import.
- **Opal Composer**: picking the white point from the image.
- **Camo**: privacy blur and overlays.
- **NVIDIA Broadcast / Apple Studio Light**: virtual key light, done here as Studio Light.

## Benchmarks
None of these vendors publish comparable speed or quality numbers, so Framelight ships its own reproducible benchmark (`Framelight --benchmark`). CI runs it on every build and posts the results to the run summary. It measures:
- pipeline speed per configuration on synthetic 4K frames
- background-blur halo versus the typical blur-then-paste method
- noise removed and ghosting versus simple temporal averaging
- skin hue drift versus RGB colour controls

## Sources
- Camo: [Camo Studio](https://reincubate.com/camo/), [Adjusting your video](https://camo.com/support/camo/adjusting-video-settings), [press release](https://www.prnewswire.com/news-releases/reincubate-extends-camos-video-enhancing-magic-to-webcams-built-in-cameras-and-connected-mirrorless-dslr-or-action-cameras-301771666.html)
- Elgato: [Camera Hub 2.0 release notes](https://help.elgato.com/hc/en-us/articles/34177528821265-Elgato-Camera-Hub-2-0-Release-Notes), [Camera Hub settings overview](https://help.elgato.com/hc/en-us/articles/4405055113357-Elgato-Facecam-Camera-Hub-Settings-Overview), [Facecam 4K review](https://www.notebookcheck.net/Streaming-upgrade-Elgato-Facecam-4K-review-with-Sony-Starvis-2-sensor-and-filter-support.1291738.0.html)
- Opal: [Composer](https://op.al/composer), [Opal C1 review](https://thesweetsetup.com/opal-c1-review/)
- Insta360: [Whiteboard mode manual](https://onlinemanual.insta360.com/link2/en-us/operating-tutorials/function-mode/whiteboard-mode), [Link 2](https://www.insta360.com/product/insta360-link2), [Pocket-lint review](https://www.pocket-lint.com/gadgets/reviews/162063-insta360-link-review/)
- OBSBOT: [OBSBOT Center first-time guide](https://note.com/obsbot/n/nff2909c444e1?hl=en), [Multi-device update](https://www.obsbot.com/explore/obsbot-center/multi-device-version-update), [Tiny 2 Lite FAQ](https://www.obsbot.com/obsbot-tiny-2-lite-4k-webcam/faq)
- NVIDIA / Logitech: [NVIDIA Broadcast integrations](https://www.nvidia.com/en-gb/geforce/news/nvidia-broadcast-engine-integrations), [Logi Tune](https://support.logi.com/hc/en-us/articles/9495594018199-Logi-Tune), [RightSight](https://prosupport.logi.com/hc/en-hk/articles/8752234111255-What-is-RightSight-and-where-can-I-find-it)
- UVC utilities: [CamDial](https://apps.apple.com/us/app/usb-webcam-settings-camdial/id6806860547?mt=12), [CamControl](https://github.com/manuelbl/CamControl), [camctl](https://github.com/jamesainslie/camctl), [Webcam Settings](https://apps.apple.com/us/app/webcam-settings/id533696630?mt=12)
