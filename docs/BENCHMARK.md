# Benchmark results

Run with `Framelight.app/Contents/MacOS/Framelight --benchmark`. CI runs it on every build, so quality regressions fail the build.

## Mac mini (Apple M6), macOS 27.3: November 2026

Input is 3840×2160 camera frames, with 1080p output unless noted.

| Configuration | Mean ms/frame | p95 ms | Max fps | Share of a 30 fps frame | Fits 60 fps (p95 < 16.7 ms) |
|---|---:|---:|---:|---:|:---:|
| Camera only (crop + scale to 1080p) | 3.9 | 4.0 | 255 | 12% | ✅ |
| Defaults (look, auto light, skin tones, noise reduction) | 6.5 | 9.8 | 155 | 20% | ✅ |
| Defaults + background blur | 10.8 | 13.9 | 92 | 32% | ✅ |
| Everything on (blur, framing, detail, name tag) | 11.5 | 14.4 | 87 | 35% | ✅ |
| Defaults at 4K output | 8.7 | 10.4 | 115 | 26% | ✅ |

## Quality versus the typical methods (same on every machine)

| Check | Typical method | Framelight |
|---|---|---|
| Halo (subject colour bleed) around a blurred background | 16.41 | **1.20** (−93%) |
| Ghost trail behind a moving dark object | 22.00 | **1.58** |
| Noise removed, typical room (4.0 RMS) | — | **2.9 dB** default, 5.8 dB max |
| Noise removed, dim room (10.0 RMS) | — | **2.9 dB** default, 5.9 dB max |
| Worst skin hue shift at contrast +15%, saturation +30% | 41.3° | **0.7°** |
| Skin saturation at the same settings | ×2.71 | **×1.08** |
| Background grain: brightness shift / strength | — | −0.06 / 1.43 levels |

Error scales are 0–255. Skin tones are taken from the Macbeth chart and the Monk scale, with hue measured in OKLab.
