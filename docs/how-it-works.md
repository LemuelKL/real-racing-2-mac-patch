# How it works

Real Racing 2 for Mac (Firemint/EA, 2011, last updated 2014) is an Intel app built against the macOS 10.8 SDK. On a current Mac it opens a white window and stays there. This page covers how each problem was found and fixed. It assumes some familiarity with C and the command line, but no prior reverse engineering.

## The tools

There's no source code, so everything came from the shipped binary and from watching it run. Only standard macOS tools were needed:

- `file`, `otool -L`, `codesign -dv`: what the app is, what it links, whether it's signed. The executable is x86_64 + i386 and unsigned.
- `sample <pid>`: stack snapshots of every thread in a running process. This found the first bug in seconds.
- `otool -tV` and `otool -ov`: disassembly, plus Objective-C class and method lists. The binary still contains its Objective-C names and C++ symbols, so functions like `-[fmOpenGLView drawView]` and `CGlobal::splash_Update` are easy to read.
- `nm -u`: the external functions a binary imports. This is how I knew FMOD calls `FindNextComponent` and `AudioHardwareGetProperty`.
- `lldb`: to confirm exactly where a crash happens.

The loop was always the same: observe, form a hypothesis, hook something, observe again.

## Getting code into the game

macOS's dynamic linker, dyld, loads any libraries listed in `DYLD_INSERT_LIBRARIES` before the program starts. It then runs their `__attribute__((constructor))` functions before the game's `main()`. That's where rr2fix installs its hooks.

`install.sh` renames the real executable to `Real Racing 2.bin` and puts a short shell script in its place. The script sets the variable and runs the original. This only works because the game is unsigned and predates the Hardened Runtime. A modern signed app would have the variable stripped.

The library is compiled for x86_64. Rosetta translates the whole process, so anything loaded into it has to be Intel code too.

Three hooking techniques are used:

- **Objective-C method swizzling.** Every `[obj method]` call is looked up by name at runtime, so `method_setImplementation` can redirect it. Used for `NSHost`, `fmOpenGLView` and the app delegate.
- **dyld interposing.** A `__DATA,__interpose` section tells dyld to bind other images' calls to a function to your replacement instead. Used for `fopen`.
- **Rewriting symbol pointers.** Calls to external functions go through pointer slots that dyld fills in. rr2fix overwrites FMOD's slots directly (more on why below).

## 1. Hang on the loading screen

`sample` during the white screen showed the render thread stuck here:

```
displayLinkCallback → -[fmOpenGLView drawView]
  → CGlobal::splash_Update → CGlobal::scene_DoIncrementalLoad
  → CloudcellService::OnInitialise
  → RR2_Cloudcell::Manager::QueueRemoteInputServerSync
  → RemoteInput::Network::getHostName
  → -[NSHost name] → -[NSHost blockingResolveUntil:] → semaphore wait
```

About 40 other threads were sitting in `getnameinfo → mdns_hostbyaddr`.

`[[NSHost currentHost] name]` reverse-resolves every address on every network interface. In 2011 a Mac had two or three. Now there are IPv6 addresses, VPN tunnels, AirDrop and other virtual interfaces, and some of those lookups never come back. The call is made synchronously while loading, so loading stops.

It also took the main thread down with it. Switching away from the game makes the main thread stop the display link, which waits for the stuck render callback.

**Fix:** `+[NSHost currentHost]` returns an `NSHost` subclass. Its `name` and `addresses` come straight from `gethostname()` and `getifaddrs()`, with no DNS at all.

## 2. Very slow loading

Next the game sat at 100% CPU in `AtlasLoader::loadImage → system_GetDirListingFromResArchive → unzGoToNextFile → fseek`. After three minutes it still hadn't reached the menu.

All the assets are in `res.bin`, a 600 MB zip with a simple XOR applied, read through minizip's stdio callbacks. To load one image, the game walks the zip's entire file list. Every step of that walk is an `fseek` plus an `fread`. Each `fseek` throws away stdio's buffer, so each step costs real `lseek` and `read` system calls. That adds up to hundreds of thousands of syscalls per screen, and syscalls are especially slow under Rosetta.

**Fix:** interpose `fopen`. For `res.bin`, map the file into memory once and return an `fmemopen()` stream over the mapping. Seeks and reads become memory copies. The game's own XOR decoding runs unchanged on top.

Jackson Dam's patcher solves the same problem differently, and more thoroughly. It writes the archive's file list to an index file and replaces the directory-listing function with a small routine that reads the index. That removes the repeated scan entirely, where mine only makes each scan cheap.

## 3. White window

With loading fixed, the game was clearly running: music played and clicks made menu sounds. The window stayed white.

The game's view, `fmOpenGLView`, is a plain `NSView` that owns an `NSOpenGLContext`. The only place it connects the two is here:

```objc
- (void)lockFocus {
    [super lockFocus];
    if ([[self openGLContext] view] != self)
        [[self openGLContext] setView:self];
}
```

This pattern came from Apple's sample code of the time, and it relied on AppKit calling `-lockFocus` before drawing. Since macOS 10.14, views are drawn through Core Animation layers and `-lockFocus` isn't called during display. The context never gets a drawable surface. Every frame is rendered and presented into nothing, and the game has no idea.

**Fix:** after `viewDidMoveToWindow`, `reshape`, `update`, `setFrameSize:` and `prepareOpenGL`, call `[context setView:self]` if it isn't already attached. This also catches the move into the fullscreen window.

Plenty of old Mac OpenGL games use the same pattern. If one shows a white or black window on modern macOS, this is a good first thing to check.

## 4. Window flushing left off

In `-applicationDidFinishLaunching:` the game calls `[window disableFlushWindow]` before creating its intro movie controller. `-willBecomeActive` turns flushing back on, but only inside an `if (movieController)` block. QTKit is a stub on modern macOS, the movie fails to load, the controller is nil, and flushing stays off.

**Fix:** swizzle `-[RealRacing2MacAppDelegate willBecomeActive]`. After the original runs, call `enableFlushWindow` if flushing is still disabled.

Credit to Jackson Dam's patcher for spotting this one.

## 5. Sound stuck on one device

Once the game worked, sound stayed on the MacBook speakers after AirPods connected.

FMOD Ex opens an AUHAL audio unit and pins it to the default device's ID with `kAudioOutputUnitProperty_CurrentDevice`. AUHAL never follows the system default by itself, and FMOD only rebinds if its device disappears.

**Fix:** when FMOD looks for the AUHAL component, give it the Default Output unit instead, which tracks the system default on its own. FMOD's AUHAL-only property calls (`CurrentDevice`, `EnableIO`) on that unit are accepted and ignored. The stream format and render callback are unchanged.

### Why FMOD needed a different hooking technique

The first version of this used dyld interposing, the same as `fopen`. It silently did nothing. `DYLD_PRINT_INTERPOSING=1` showed the game binary being patched, but never FMOD.

The bundled `libfmodex.dylib` dates from the Mac OS X 10.5 era. It has no `LC_DYLD_INFO` load command and binds imports through the old indirect symbol table, which modern dyld's interposing skips. So rr2fix waits for FMOD to load (`_dyld_register_func_for_add_image`). It then walks FMOD's load commands, matches each lazy and non-lazy symbol pointer to its name through the indirect symbol table, and overwrites the slots for the functions it cares about. This is the same idea as Facebook's fishhook, and as IAT hooking on Windows.

The lesson: check that a hook actually runs before you trust it.

## 6. Crash with no default input device

This one is also from Jackson Dam's patcher. I confirmed it and fixed it differently.

When FMOD builds its device lists, it first asks CoreAudio for the default output and default input devices and puts each at the top of its list. It then goes through every device. A device with input channels is added to the input list, unless its name matches entry 0 of that list.

The bug is in that check. Before comparing names, FMOD tests that the list isn't empty, but it tests the *output* list's count instead of the input list's. If macOS reports no default input device, the input list is empty, the wrong check passes, and the name comparison reads entry 0's name, which is NULL:

```
0x56ad  movl  0x258(%r14), %edx    ; output count (should be the input count at 0x468)
0x56b6  je    error
...
0x56c6  movq  0x478(%r14), %rsi    ; input entry 0 name: NULL when the list is empty
0x56d4  callq strcmp-like          ; crashes reading (%rsi)
```

This happens on a Mac that has some input-capable device but no default input. An example is a desktop Mac without a microphone that has a virtual audio device from Teams, Zoom or similar installed.

I reproduced it with a small test program that loads FMOD and lists the recording devices, plus a shim that makes CoreAudio report no default input. With the fix disabled it segfaults; `lldb` shows a NULL read at `0x76306`, FMOD's string-compare helper. With the fix enabled it lists every input device and exits normally.

**Fix:** hook FMOD's `AudioHardwareGetProperty` (via the symbol-pointer rewriting above). When it asks for the default input and gets none, answer with the first device that has input channels. If no device has input channels, FMOD never reaches the comparison, so nothing needs changing.

Jackson's patcher edits the instruction instead, so it checks the right count and adds the device straight away. Same result.

## Odds and ends

- **A white screen with working audio is a useful clue.** It means the game is running and its frames are going nowhere, which is a different problem from a freeze. Here both happened, one after the other.
- **Rosetta 2 deserves credit.** A 2011 Intel game linked against QTKit, `libcrypto.0.9.8` and `libstdc++` runs fine on an M2. Every problem was in the OS APIs around it, not in CPU translation. OpenGL 2.1 is still served by Apple's Metal-backed layer.
- **Skipping the intro without Accessibility permission.** For testing, `RR2FIX_AUTOSPACE=6` posts a Space key event from inside the game after 6 seconds. An in-process `[NSApp postEvent:]` needs no permission.
- **Leftovers in the binary:** the build path `/MobileDevelopment/Hudson/workspace/RR2_Desktop_MacOS/...`, a class called `fmMovieViewControllerSnowLeopard`, touch-input methods from the iPhone version, and a log message that literally says "Break here ... and repair the shader".
- **Rosetta's future:** Apple has said Rosetta 2 will be cut back after macOS 27 to a subset aimed at older games. Whether this game keeps working after that is an open question.
