# rr2fix

Gets the 2011 Mac version of Real Racing 2 running again on modern macOS, including Apple Silicon Macs.

Out of the box the game shows a white window forever. With this installed it loads to the menu and plays normally, sound included.

The game's own files are left unchanged. rr2fix is a small library that the game loads at launch. It hooks the handful of system calls that broke on newer macOS. Uninstalling puts everything back exactly as it was.

## Requirements

- Your own copy of Real Racing 2 for Mac. Version 1.1.2 is tested. 1.0.0 may work but hasn't been tried.
- On Apple Silicon: Rosetta 2 (`softwareupdate --install-rosetta`)
- Xcode Command Line Tools, to compile the library (`xcode-select --install`)

Tested on a MacBook Air M2 with macOS 27.

## Install

```sh
git clone https://github.com/LemuelKL/rr2fix.git
cd rr2fix
./install.sh
```

Then open the game as usual and press Space at the intro screen.

If the game isn't in `/Applications`:

```sh
APP="/path/to/Real Racing 2.app" ./install.sh
```

To uninstall:

```sh
./install.sh --uninstall
```

## What it fixes

1. **Hang on the loading screen.** The game asks macOS for the computer's hostname on its render thread. On a modern Mac that turns into reverse DNS lookups that never finish.
2. **Very slow loading.** Every texture load rescans the 600 MB asset archive with thousands of tiny reads. These are expensive under Rosetta.
3. **White window.** The game only connects its OpenGL context to the window from `-lockFocus`, which AppKit stopped calling in macOS 10.14.
4. **Window flushing left off.** The game turns flushing off for its intro movie and only turns it back on if the movie loads. QTKit can't load it any more.
5. **Sound stuck on one device.** FMOD, the game's audio library, binds to whatever output was the default at launch. It now follows the system output, so switching to AirPods works.
6. **Crash with no default input device.** A bug in FMOD's device listing reads a NULL name when macOS reports no default microphone.
7. **Phone tilt steering.** The game's phone controller page steers with motion sensors, which phone browsers now only allow on HTTPS pages. rr2fix serves the page over HTTPS and adapts it for current browsers.

[docs/how-it-works.md](docs/how-it-works.md) explains how each problem was tracked down and how the hook works.

## Phone controller

The game can use your phone as a steering wheel. Open the address the game shows (for example `http://192.168.1.20:2011`) on your phone, then tap **Open controller**. This goes to `https://<your Mac>:2012`.

The browser warns that the connection isn't private, because the certificate was made by rr2fix on your Mac. Continue anyway (Safari: Show Details, then visit this website. Chrome: Advanced, then Proceed). On iPhone, tap the page once to allow motion access.

If the iPhone page loads but never connects, install the certificate linked on the landing page. Then turn it on in Settings > General > About > Certificate Trust Settings. It is limited to private network addresses. The certificate files are in `~/Library/Application Support/rr2fix`.

If steering is reversed, add `?flip` to the end of the controller address.

## Troubleshooting

To see the logs, run the game from Terminal:

```sh
RR2FIX_DEBUG=1 "/Applications/Real Racing 2.app/Contents/MacOS/Real Racing 2"
```

You should see a line like `rr2fix: attached GL context to <fmOpenGLView ...>`. If it's missing, the library didn't load.

Messages you can ignore:

- `StoreRec: Error 1d`: the old App Store receipt check fails, and the game carries on anyway.
- `[[QTMovie alloc] initWithAttributes:error:] failed`: the intro video can't play. Press Space.
- `mtShader::loadFileSource failed ... car_body_shadow.vsh`: these files are missing from the game itself.

Known quirks:

- No intro video.
- Online features don't work, because EA's servers are gone.
- Fullscreen changes your display resolution, the same as it did in 2011.

## Project layout

```
install.sh            build, install, uninstall
src/rr2fix.m          the fixes, one section per problem
src/remote/           the phone controller's landing page and the script added to it
docs/how-it-works.md  the investigation
```

## Credits

Fixes 4 and 6 come from Jackson Dam's [real-racing-2-mac-patcher](https://github.com/JacksonDam/real-racing-2-mac-patcher), which found them independently. His patcher takes a different approach and edits the game's binary directly. It also supports version 1.0.0 and has a GUI, so check it out if that suits you better.

The FMOD hooks use the same idea as Facebook's [fishhook](https://github.com/facebook/fishhook).

## Legal

This repository contains no code or assets from EA or Firemint. You need your own copy of the game. rr2fix doesn't touch the App Store receipt check or any copy protection. Real Racing 2 is a trademark of Electronic Arts.

MIT licensed. See [LICENSE](LICENSE).
