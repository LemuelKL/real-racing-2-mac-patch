// rr2fix: makes Real Racing 2 (Mac, 2011-2014) run on modern macOS.
//
// Loaded into the game with DYLD_INSERT_LIBRARIES (see install.sh). Built for x86_64,
// because the game runs under Rosetta and so does everything loaded into it.
// The game's files are not modified; every fix is a hook installed at launch.
//
//   1. Startup hang      +[NSHost currentHost] blocks forever on reverse DNS.
//   2. Slow loading      Every image load rescans res.bin with an fseek+fread per entry.
//   3. White screen      The OpenGL context is never attached to its view on 10.14+.
//   4. Window flushing   Left disabled because the QTKit intro movie fails to load.
//   5. Audio device      FMOD stays on the output device that was default at launch.
//   6. No-input crash    FMOD crashes when there is no default input device.
//
// Fixes 4 and 6 follow Jackson Dam's binary patcher:
// https://github.com/JacksonDam/real-racing-2-mac-patcher
//
// Debugging: RR2FIX_DEBUG=1 logs each hook to stderr.
// RR2FIX_AUTOSPACE=<seconds> presses Space inside the game to skip the intro screen.

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreServices/CoreServices.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <net/if.h>
#include <netdb.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define DBG(...) do { if (getenv("RR2FIX_DEBUG")) fprintf(stderr, "rr2fix: " __VA_ARGS__); } while (0)

static int hasSuffix(const char *s, const char *suffix) {
    size_t ls = strlen(s), lx = strlen(suffix);
    return ls >= lx && strcmp(s + ls - lx, suffix) == 0;
}

#pragma mark - 1. Startup hang

// While loading, the render thread calls [[NSHost currentHost] name]. On a modern Mac
// that reverse-resolves every interface address over mDNS, and the lookups never
// return. We answer from gethostname() and getifaddrs() instead, with no DNS.

@interface RR2FastHost : NSHost
@end

@implementation RR2FastHost

- (NSString *)name {
    char buf[256] = {0};
    if (gethostname(buf, sizeof(buf) - 1) != 0 || buf[0] == '\0')
        return @"localhost";
    return [NSString stringWithUTF8String:buf];
}

- (NSArray *)names {
    return @[[self name], @"localhost"];
}

- (NSString *)localizedName {
    return [self name];
}

- (NSArray *)addresses {
    NSMutableArray *result = [NSMutableArray array];
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) == 0) {
        for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
            if (!i->ifa_addr || !(i->ifa_flags & IFF_UP)) continue;
            int fam = i->ifa_addr->sa_family;
            if (fam != AF_INET && fam != AF_INET6) continue;
            socklen_t len = fam == AF_INET ? sizeof(struct sockaddr_in) : sizeof(struct sockaddr_in6);
            char host[NI_MAXHOST];
            if (getnameinfo(i->ifa_addr, len, host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
                NSString *s = [NSString stringWithUTF8String:host];
                if (![result containsObject:s]) [result addObject:s];
            }
        }
        freeifaddrs(ifs);
    }
    if (result.count == 0) [result addObject:@"127.0.0.1"];
    return result;
}

- (NSString *)address {
    return [[self addresses] firstObject];
}

- (BOOL)isEqualToHost:(NSHost *)other {
    return other == self;
}

@end

static NSHost *fastCurrentHost(id cls, SEL _cmd) {
    static NSHost *host;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        host = (NSHost *)class_createInstance([RR2FastHost class], 0);
    });
    return host;
}

static void installHostFix(void) {
    Method m = class_getClassMethod([NSHost class], @selector(currentHost));
    if (m) method_setImplementation(m, (IMP)fastCurrentHost);
}

#pragma mark - 2. Slow loading

// All assets live in res.bin, a 600 MB zip read through stdio. Each image load walks
// the whole central directory, and every step is an fseek that drops the stdio buffer
// and makes real syscalls, which are slow under Rosetta. We map the file once and give
// the game fmemopen() streams over the mapping, so seeks and reads become memcpy.

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

// Shared by every stream and never unmapped.
static void *resBase;
static size_t resSize;

static FILE *rr2_fopen(const char *path, const char *mode) {
    if (path && mode && mode[0] == 'r' && !strchr(mode, '+') && hasSuffix(path, "/res.bin")) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            int fd = open(path, O_RDONLY);
            struct stat st;
            if (fd >= 0 && fstat(fd, &st) == 0 && st.st_size > 0) {
                void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
                if (p != MAP_FAILED) {
                    resBase = p;
                    resSize = (size_t)st.st_size;
                }
            }
            if (fd >= 0) close(fd);
        });
        if (resBase) {
            FILE *f = fmemopen(resBase, resSize, "rb");
            if (f) return f;
        }
    }
    return fopen(path, mode);
}
DYLD_INTERPOSE(rr2_fopen, fopen)

#pragma mark - 3. White screen

// fmOpenGLView only attaches its NSOpenGLContext inside -lockFocus, which AppKit stopped
// calling during display in macOS 10.14. The game renders into a context with no
// drawable, so the window stays white. We attach it whenever the view's window or
// geometry changes, which also covers the switch to fullscreen.

static void attachGLContext(NSView *view) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ attachGLContext(view); });
        return;
    }
    if (!view.window || ![view respondsToSelector:@selector(openGLContext)]) return;
    NSOpenGLContext *ctx = [(id)view openGLContext];
    if (!ctx || ctx.view == view) return;
    CGLLockContext(ctx.CGLContextObj);
    [ctx setView:view];
    [ctx update];
    CGLUnlockContext(ctx.CGLContextObj);
    NSLog(@"rr2fix: attached GL context to %@ (frame %@)", view, NSStringFromRect(view.frame));
}

static void hookAttach(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    // Hooked selectors take no argument or a single NSSize (setFrameSize:), so
    // declaring the original as (id, SEL, NSSize) forwards both correctly.
    typedef void (*Fn)(id, SEL, NSSize);
    Fn orig = (Fn)method_getImplementation(m);
    IMP imp = imp_implementationWithBlock(^(id self, NSSize arg) {
        orig(self, sel, arg);
        attachGLContext(self);
    });
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m)))
        method_setImplementation(m, imp);
}

static void installGLFix(void) {
    Class cls = objc_getClass("fmOpenGLView");
    if (!cls) return;
    hookAttach(cls, @selector(viewDidMoveToWindow));
    hookAttach(cls, @selector(reshape));
    hookAttach(cls, @selector(update));
    hookAttach(cls, @selector(setFrameSize:));
    hookAttach(cls, @selector(prepareOpenGL));
}

#pragma mark - 4. Window flushing

// At launch the game calls -disableFlushWindow before setting up its intro movie, and
// -willBecomeActive only turns flushing back on once the movie controller exists.
// QTKit can't load the movie any more, so the controller is nil and flushing stays off.
// We turn it back on after -willBecomeActive runs.

static void installFlushFix(void) {
    Class cls = objc_getClass("RealRacing2MacAppDelegate");
    Method m = class_getInstanceMethod(cls, @selector(willBecomeActive));
    Ivar windowIvar = class_getInstanceVariable(cls, "window");
    if (!m || !windowIvar) return;
    typedef void (*Fn)(id, SEL);
    Fn orig = (Fn)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self) {
        orig(self, @selector(willBecomeActive));
        __unsafe_unretained NSWindow *window = object_getIvar(self, windowIvar);
        if (window.isFlushWindowDisabled) {
            [window enableFlushWindow];
            DBG("re-enabled window flushing\n");
        }
    }));
}

#pragma mark - 5. Audio device

// FMOD Ex opens an AUHAL unit and pins it to the default output device at startup,
// so sound stays on the speakers after AirPods connect. We hand FMOD the Default Output
// unit instead, which follows the system default by itself, and accept FMOD's
// AUHAL-only properties on it as no-ops.

static Component defaultOutputComponent;
static ComponentInstance defaultOutputUnits[8];
static int defaultOutputUnitCount;

static Component rr2_FindNextComponent(Component prev, ComponentDescription *desc) {
    if (desc && desc->componentType == kAudioUnitType_Output &&
        desc->componentSubType == kAudioUnitSubType_HALOutput &&
        desc->componentManufacturer == kAudioUnitManufacturer_Apple) {
        ComponentDescription def = *desc;
        def.componentSubType = kAudioUnitSubType_DefaultOutput;
        Component c = FindNextComponent(prev, &def);
        DBG("FindNextComponent: AUHAL -> DefaultOutput %p\n", c);
        if (c) return defaultOutputComponent = c;
    }
    return FindNextComponent(prev, desc);
}

static OSErr rr2_OpenAComponent(Component c, ComponentInstance *out) {
    OSErr r = OpenAComponent(c, out);
    if (r == noErr && c == defaultOutputComponent && defaultOutputUnitCount < 8)
        defaultOutputUnits[defaultOutputUnitCount++] = *out;
    return r;
}

static BOOL isDefaultOutputUnit(AudioUnit unit) {
    for (int i = 0; i < defaultOutputUnitCount; i++)
        if ((AudioUnit)defaultOutputUnits[i] == unit) return YES;
    return NO;
}

static OSStatus rr2_AudioUnitSetProperty(AudioUnit unit, AudioUnitPropertyID prop, AudioUnitScope scope,
                                         AudioUnitElement elem, const void *data, UInt32 size) {
    // Only AUHAL has these. The Default Output unit always outputs, has no input side
    // and picks its own device.
    if (isDefaultOutputUnit(unit) &&
        (prop == kAudioOutputUnitProperty_CurrentDevice || prop == kAudioOutputUnitProperty_EnableIO)) {
        DBG("AudioUnitSetProperty %u on DefaultOutput: ignored\n", prop);
        return noErr;
    }
    return AudioUnitSetProperty(unit, prop, scope, elem, data, size);
}

#pragma mark - 6. No-input crash

// FMOD seeds its input list with the default input device, then adds every device that
// has input channels, comparing names against the first entry. With no default input
// (a Mac with no microphone but a virtual input device, say) the list is empty, a
// wrong count check lets the comparison run anyway, and it reads a NULL name.
// When CoreAudio reports no default input, we report the first device with input
// channels instead. If there is none, FMOD never reaches that comparison.

static UInt32 inputChannels(AudioObjectID dev) {
    AudioObjectPropertyAddress addr = {kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, 0};
    UInt32 size = 0, channels = 0;
    if (AudioObjectGetPropertyDataSize(dev, &addr, 0, NULL, &size) != noErr || size == 0) return 0;
    AudioBufferList *list = malloc(size);
    if (list && AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, list) == noErr)
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) channels += list->mBuffers[i].mNumberChannels;
    free(list);
    return channels;
}

static AudioDeviceID firstInputDevice(void) {
    AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, 0};
    UInt32 size = 0;
    AudioDeviceID found = kAudioDeviceUnknown;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr) return found;
    AudioDeviceID *devs = malloc(size);
    if (devs && AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devs) == noErr)
        for (UInt32 i = 0; i < size / sizeof(*devs) && found == kAudioDeviceUnknown; i++)
            if (inputChannels(devs[i]) > 0) found = devs[i];
    free(devs);
    return found;
}

static OSStatus rr2_AudioHardwareGetProperty(AudioHardwarePropertyID prop, UInt32 *size, void *data) {
    OSStatus r = AudioHardwareGetProperty(prop, size, data);
    if (prop == kAudioHardwarePropertyDefaultInputDevice && size && *size >= sizeof(AudioDeviceID) && data &&
        (r != noErr || *(AudioDeviceID *)data == kAudioDeviceUnknown)) {
        AudioDeviceID dev = firstInputDevice();
        DBG("no default input device, using %u\n", dev);
        if (dev != kAudioDeviceUnknown) {
            *(AudioDeviceID *)data = dev;
            *size = sizeof(dev);
            r = noErr;
        }
    }
    return r;
}

#pragma mark - FMOD hook installation

// libfmodex.dylib predates LC_DYLD_INFO and binds its imports through the classic
// indirect symbol table, which dyld's interposing no longer reaches. So once it loads
// we rewrite its symbol pointers ourselves, like Facebook's fishhook.

typedef struct { const char *name; void *replacement; } Rebinding;

static const Rebinding fmodRebindings[] = {
    {"_FindNextComponent", (void *)rr2_FindNextComponent},
    {"_OpenAComponent", (void *)rr2_OpenAComponent},
    {"_AudioUnitSetProperty", (void *)rr2_AudioUnitSetProperty},
    {"_AudioHardwareGetProperty", (void *)rr2_AudioHardwareGetProperty},
};

static void rebindImage(const struct mach_header_64 *mh, intptr_t slide) {
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const void *)lc;
        else if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const void *)lc;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);

    lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        const struct section_64 *sect = (const void *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **ptrs = (void **)((uintptr_t)slide + sect->addr);
            for (uint64_t k = 0; k < sect->size / sizeof(void *); k++) {
                uint32_t symIndex = indirect[sect->reserved1 + k];
                if (symIndex & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL)) continue;
                const char *name = strs + syms[symIndex].n_un.n_strx;
                for (size_t r = 0; r < sizeof(fmodRebindings) / sizeof(*fmodRebindings); r++) {
                    if (strcmp(name, fmodRebindings[r].name) != 0) continue;
                    uintptr_t page = (uintptr_t)&ptrs[k] & ~(uintptr_t)(getpagesize() - 1);
                    mprotect((void *)page, getpagesize(), PROT_READ | PROT_WRITE);
                    ptrs[k] = fmodRebindings[r].replacement;
                    DBG("rebound %s in libfmodex\n", name);
                }
            }
        }
    }
}

static void onImageAdded(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (mh->magic == MH_MAGIC_64 && dladdr(mh, &info) && info.dli_fname && hasSuffix(info.dli_fname, "/libfmodex.dylib"))
        rebindImage((const struct mach_header_64 *)mh, slide);
}

#pragma mark - Debug: auto Space

// Posting the event from inside the process needs no Accessibility permission.
static void postKey(NSEventType type) {
    NSWindow *w = [NSApp keyWindow] ?: [[NSApp windows] firstObject];
    NSEvent *e = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0
                                 timestamp:[[NSProcessInfo processInfo] systemUptime]
                              windowNumber:w.windowNumber context:nil characters:@" "
               charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
    [NSApp postEvent:e atStart:NO];
}

static void scheduleAutoSpace(void) {
    const char *s = getenv("RR2FIX_AUTOSPACE");
    if (!s) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(s) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        postKey(NSEventTypeKeyDown);
        postKey(NSEventTypeKeyUp);
    });
}

#pragma mark -

// Runs before the game's main(), once dyld has loaded the game and its libraries.
__attribute__((constructor))
static void rr2fix_init(void) {
    installHostFix();
    installGLFix();
    installFlushFix();
    _dyld_register_func_for_add_image(onImageAdded);
    scheduleAutoSpace();
}
