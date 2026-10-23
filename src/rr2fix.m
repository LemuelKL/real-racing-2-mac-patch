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
//   7. Phone steering    Phone browsers only allow tilt input on HTTPS pages.
//
// Fixes 4 and 6 follow Jackson Dam's binary patcher:
// https://github.com/JacksonDam/real-racing-2-mac-patcher
//
// Debugging: RR2FIX_DEBUG=1 logs each hook to stderr.
// RR2FIX_AUTOSPACE=<seconds> presses Space inside the game to skip the intro screen.
// RR2FIX_NO_REMOTE=1 leaves the game's phone controller server as it was.

#import <Cocoa/Cocoa.h>
#import <OpenGL/OpenGL.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreServices/CoreServices.h>
#import <Network/Network.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
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

#pragma mark - 7. Phone steering

// The game serves a phone controller page (RR2Controller/ in res.bin) over plain HTTP
// on port 2011. Touches and buttons go over a WebSocket and still work, but steering
// comes from devicemotion events, which phone browsers now only deliver to HTTPS pages,
// and on iOS only after a permission prompt.
//
// So we move the game's server to 127.0.0.1:2011 and answer the network side of port
// 2011 ourselves, with a landing page that links to HTTPS on port 2012. That port relays
// to the game and inserts remote.js into the controller page, which switches it to wss://,
// asks for motion permission and corrects the axes. The certificate comes from a local CA
// that rr2fix creates with openssl, limited to private network addresses.

#define REMOTE_PORT 2011
#define REMOTE_TLS_PORT "2012"

@interface RR2Stream : NSObject {
@public
    int fd;                 // plain TCP socket, or -1
    nw_connection_t conn;   // TLS connection from the listener
}
@end

@implementation RR2Stream

- (ssize_t)read:(void *)buf max:(size_t)max {
    if (!conn) {
        ssize_t n;
        do n = recv(fd, buf, max, 0); while (n < 0 && errno == EINTR);
        return n;
    }
    __block ssize_t n = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    nw_connection_receive(conn, 1, (uint32_t)max, ^(dispatch_data_t content, nw_content_context_t ctx, bool complete, nw_error_t err) {
        if (content && dispatch_data_get_size(content) > 0) {
            n = 0;
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *p, size_t size) {
                memcpy((char *)buf + offset, p, size);
                n = offset + size;
                return true;
            });
        } else if (complete && !err) {
            n = 0;
        }
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return n;
}

- (BOOL)write:(const void *)buf length:(size_t)len {
    if (!conn) {
        while (len > 0) {
            ssize_t n = send(fd, buf, len, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return NO;
            buf = (const char *)buf + n;
            len -= n;
        }
        return YES;
    }
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_data_t data = dispatch_data_create(buf, len, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    nw_connection_send(conn, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, false, ^(nw_error_t err) {
        ok = !err;
        dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return ok;
}

- (BOOL)writeData:(NSData *)data {
    return [self write:data.bytes length:data.length];
}

// Unblocks any read or write in progress. Safe to call more than once.
- (void)shut {
    if (conn) nw_connection_cancel(conn);
    else shutdown(fd, SHUT_RDWR);
}

- (void)dealloc {
    if (!conn && fd >= 0) close(fd);
}

@end

static RR2Stream *plainStream(int fd) {
    RR2Stream *s = [RR2Stream new];
    s->fd = fd;
    return s;
}

static RR2Stream *connectToGame(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(REMOTE_PORT)};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return nil;
    }
    return plainStream(fd);
}

static void detach(void (^block)(void)) {
    [NSThread detachNewThreadWithBlock:block];
}

#pragma mark HTTP

// Reads until buf holds a complete header block. Returns its length, or -1.
static NSInteger readHead(RR2Stream *s, NSMutableData *buf) {
    for (;;) {
        const char *p = memmem(buf.bytes, buf.length, "\r\n\r\n", 4);
        if (p) return p - (const char *)buf.bytes + 4;
        if (buf.length > 65536) return -1;
        char tmp[4096];
        ssize_t n = [s read:tmp max:sizeof(tmp)];
        if (n <= 0) return -1;
        [buf appendBytes:tmp length:n];
    }
}

static NSString *headString(NSData *buf, NSInteger len) {
    return [[NSString alloc] initWithBytes:buf.bytes length:len encoding:NSISOLatin1StringEncoding];
}

static NSString *headerValue(NSString *head, NSString *name) {
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound &&
            [[line substringToIndex:colon.location] caseInsensitiveCompare:name] == NSOrderedSame)
            return [[line substringFromIndex:colon.location + 1]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

// The request path without its query string.
static NSString *requestPath(NSString *head) {
    NSArray *parts = [[head componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    if (parts.count < 2) return @"";
    return [parts[1] componentsSeparatedByString:@"?"].firstObject;
}

static BOOL sendResponse(RR2Stream *s, NSString *status, NSString *type, NSData *body, BOOL keepAlive) {
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %@\r\nContent-Type: %@\r\nContent-Length: %lu\r\nCache-Control: no-store\r\nConnection: %@\r\n\r\n",
        status, type, (unsigned long)body.length, keepAlive ? @"keep-alive" : @"close"];
    return [s writeData:[head dataUsingEncoding:NSISOLatin1StringEncoding]] && [s writeData:body];
}

static BOOL sendGameUnavailable(RR2Stream *s) {
    NSData *body = [@"<html><body style='font:18px sans-serif'><h1>Real Racing 2 isn't answering</h1>"
                     "<p>Make sure the game is running and in front, then reload this page.</p></body></html>"
                    dataUsingEncoding:NSUTF8StringEncoding];
    return sendResponse(s, @"503 Service Unavailable", @"text/html; charset=utf-8", body, NO);
}

// Files built into this library with -sectcreate (see install.sh).
static NSData *embeddedFile(const char *section) {
    Dl_info info;
    unsigned long size = 0;
    if (!dladdr((const void *)embeddedFile, &info)) return nil;
    uint8_t *p = getsectiondata(info.dli_fbase, "__TEXT", section, &size);
    return p ? [NSData dataWithBytesNoCopy:p length:size freeWhenDone:NO] : nil;
}

#pragma mark Certificate

static NSString *certDir(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/rr2fix"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0700} error:nil];
    return dir;
}

static NSArray<NSString *> *lanAddresses(void) {
    NSMutableArray *result = [NSMutableArray array];
    struct ifaddrs *ifs = NULL;
    if (getifaddrs(&ifs) != 0) return result;
    for (struct ifaddrs *i = ifs; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
        if (!(i->ifa_flags & IFF_UP) || (i->ifa_flags & IFF_LOOPBACK)) continue;
        char host[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)i->ifa_addr)->sin_addr, host, sizeof(host));
        NSString *s = @(host);
        if (![result containsObject:s]) [result addObject:s];
    }
    freeifaddrs(ifs);
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

static BOOL openssl(NSString *dir, NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/openssl"];
    task.arguments = args;
    task.currentDirectoryURL = [NSURL fileURLWithPath:dir];
    task.standardOutput = task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:nil]) return NO;
    [task waitUntilExit];
    if (task.terminationStatus != 0) DBG("openssl %s failed\n", args.firstObject.UTF8String);
    return task.terminationStatus == 0;
}

// Creates the CA once, and a server certificate for this Mac's current addresses
// whenever they change. Phones that trust the CA then trust each new server certificate.
static sec_identity_t loadIdentity(void) {
    NSString *dir = certDir();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *ips = lanAddresses();
    if (ips.count == 0) return nil;

    NSMutableString *cnf = [NSMutableString stringWithString:
        @"[req]\ndistinguished_name = dn\n[dn]\n"
        @"[ca]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign,cRLSign\n"
        @"subjectKeyIdentifier = hash\n"
        @"nameConstraints = critical,permitted;IP:10.0.0.0/255.0.0.0,permitted;IP:172.16.0.0/255.240.0.0,"
        @"permitted;IP:192.168.0.0/255.255.0.0,permitted;IP:100.64.0.0/255.192.0.0\n"
        @"[leaf]\nbasicConstraints = critical,CA:FALSE\nkeyUsage = critical,digitalSignature,keyEncipherment\n"
        @"extendedKeyUsage = serverAuth\nsubjectKeyIdentifier = hash\nauthorityKeyIdentifier = keyid\n"
        @"subjectAltName = @alt\n[alt]\n"];
    for (NSUInteger i = 0; i < ips.count; i++) [cnf appendFormat:@"IP.%lu = %@\n", (unsigned long)i + 1, ips[i]];
    [cnf writeToFile:[dir stringByAppendingPathComponent:@"openssl.cnf"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    if (![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"rr2fix-ca.cer"]]) {
        if (!openssl(dir, @[@"req", @"-x509", @"-new", @"-newkey", @"rsa:2048", @"-nodes", @"-sha256", @"-days", @"3650",
                            @"-subj", @"/CN=rr2fix Real Racing 2 controller CA", @"-config", @"openssl.cnf",
                            @"-extensions", @"ca", @"-keyout", @"ca.key", @"-out", @"ca.crt"]) ||
            !openssl(dir, @[@"x509", @"-in", @"ca.crt", @"-outform", @"der", @"-out", @"rr2fix-ca.cer"]))
            return nil;
        [fm removeItemAtPath:[dir stringByAppendingPathComponent:@"server.p12"] error:nil];
    }

    // Phones reject server certificates valid for more than 398 days, so renew yearly.
    NSString *p12Path = [dir stringByAppendingPathComponent:@"server.p12"];
    NSString *ipsPath = [dir stringByAppendingPathComponent:@"server.ips"];
    // Bump the prefix when the certificate format changes, to remake existing ones.
    NSString *ipList = [@"v2:" stringByAppendingString:[ips componentsJoinedByString:@","]];
    NSDate *made = [fm attributesOfItemAtPath:p12Path error:nil].fileModificationDate;
    if (!made || -made.timeIntervalSinceNow > 360 * 86400 ||
        ![[NSString stringWithContentsOfFile:ipsPath encoding:NSUTF8StringEncoding error:nil] isEqualToString:ipList]) {
        DBG("making server certificate for %s\n", ipList.UTF8String);
        if (!openssl(dir, @[@"req", @"-new", @"-newkey", @"rsa:2048", @"-nodes", @"-sha256", @"-subj", @"/CN=Real Racing 2",
                            @"-config", @"openssl.cnf", @"-keyout", @"server.key", @"-out", @"server.csr"]) ||
            !openssl(dir, @[@"x509", @"-req", @"-sha256", @"-days", @"397", @"-in", @"server.csr", @"-CA", @"ca.crt",
                            @"-CAkey", @"ca.key", @"-CAserial", @"ca.srl", @"-CAcreateserial",
                            @"-extfile", @"openssl.cnf", @"-extensions", @"leaf", @"-out", @"server.crt"]) ||
            !openssl(dir, @[@"pkcs12", @"-export", @"-passout", @"pass:rr2fix", @"-keypbe", @"PBE-SHA1-3DES",
                            @"-certpbe", @"PBE-SHA1-3DES", @"-macalg", @"sha1", @"-inkey", @"server.key",
                            @"-in", @"server.crt", @"-certfile", @"ca.crt", @"-out", @"server.p12"]))
            return nil;
        [ipList writeToFile:ipsPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }

    NSData *p12 = [NSData dataWithContentsOfFile:p12Path];
    if (!p12) return nil;
    NSMutableDictionary *opts = [@{(__bridge id)kSecImportExportPassphrase: @"rr2fix"} mutableCopy];
    if (@available(macOS 15, *)) opts[(__bridge id)kSecImportToMemoryOnly] = @YES;
    CFArrayRef items = NULL;
    OSStatus st = SecPKCS12Import((__bridge CFDataRef)p12, (__bridge CFDictionaryRef)opts, &items);
    if (st != errSecSuccess || !items || CFArrayGetCount(items) == 0) {
        DBG("SecPKCS12Import failed: %d\n", (int)st);
        if (items) CFRelease(items);
        return nil;
    }
    SecIdentityRef identity = (SecIdentityRef)CFDictionaryGetValue(CFArrayGetValueAtIndex(items, 0), kSecImportItemIdentity);
    sec_identity_t result = identity ? sec_identity_create(identity) : nil;
    CFRelease(items);
    return result;
}

#pragma mark Relay

static void copyStream(RR2Stream *from, RR2Stream *to) {
    char buf[16384];
    ssize_t n;
    while ((n = [from read:buf max:sizeof(buf)]) > 0)
        if (![to write:buf length:n]) break;
}

// Copies both ways until either side closes.
static void relay(RR2Stream *a, RR2Stream *b) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    detach(^{
        copyStream(b, a);
        [a shut];
        [b shut];
        dispatch_semaphore_signal(done);
    });
    copyStream(a, b);
    [a shut];
    [b shut];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

// Fetches one request from the game and passes the response on. On the secure side,
// inserts remote.js at the top of the controller page.
static BOOL relayRequest(RR2Stream *client, NSData *request, NSString *path, BOOL secure) {
    RR2Stream *game = connectToGame();
    if (!game || ![game writeData:request]) return sendGameUnavailable(client);
    NSMutableData *buf = [NSMutableData data];
    NSInteger headLen = readHead(game, buf);
    if (headLen < 0) return sendGameUnavailable(client);
    NSString *head = headString(buf, headLen);
    NSString *lengthHeader = headerValue(head, @"Content-Length");
    NSInteger want = lengthHeader ? headLen + lengthHeader.integerValue : NSIntegerMax;
    char tmp[16384];
    ssize_t n;
    while ((NSInteger)buf.length < want && (n = [game read:tmp max:sizeof(tmp)]) > 0)
        [buf appendBytes:tmp length:n];
    [game shut];

    NSMutableData *body = [[buf subdataWithRange:NSMakeRange(headLen, MIN(buf.length, (NSUInteger)want) - headLen)] mutableCopy];
    if (secure && [path hasSuffix:@"/RR2Controller/index.html"]) {
        NSData *tag = [@"\n<script src=\"/rr2fix/remote.js\"></script>" dataUsingEncoding:NSUTF8StringEncoding];
        NSRange r = [body rangeOfData:[@"<head>" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, body.length)];
        if (r.location != NSNotFound) [body replaceBytesInRange:NSMakeRange(NSMaxRange(r), 0) withBytes:tag.bytes length:tag.length];
    }

    // Rewrite the length and keep the browser's connection open.
    NSMutableString *out = [NSMutableString string];
    for (NSString *line in [head componentsSeparatedByString:@"\r\n"]) {
        if (line.length == 0) continue;
        NSString *lower = line.lowercaseString;
        if ([lower hasPrefix:@"content-length:"] || [lower hasPrefix:@"connection:"] || [lower hasPrefix:@"keep-alive:"]) continue;
        [out appendFormat:@"%@\r\n", line];
    }
    [out appendFormat:@"Content-Length: %lu\r\nConnection: keep-alive\r\n\r\n", (unsigned long)body.length];
    return [client writeData:[out dataUsingEncoding:NSISOLatin1StringEncoding]] && [client writeData:body];
}

// Serves one browser connection. Plain HTTP shows the landing page, HTTPS relays the
// controller, and WebSockets on either go straight through to the game.
static void serveClient(RR2Stream *client, BOOL secure) {
    NSMutableData *buf = [NSMutableData data];
    for (;;) {
        NSInteger headLen = readHead(client, buf);
        if (headLen < 0) break;
        NSString *head = headString(buf, headLen);
        NSString *path = requestPath(head);

        if ([[headerValue(head, @"Upgrade") lowercaseString] isEqualToString:@"websocket"]) {
            RR2Stream *game = connectToGame();
            if (!game) { sendGameUnavailable(client); break; }
            DBG("phone controller connected (%s)\n", secure ? "https" : "http");
            if ([game writeData:buf]) relay(client, game);
            DBG("phone controller disconnected\n");
            return;
        }

        NSData *request = [buf subdataWithRange:NSMakeRange(0, headLen)];
        [buf replaceBytesInRange:NSMakeRange(0, headLen) withBytes:NULL length:0];
        BOOL ok;
        if ([path isEqualToString:@"/rr2fix/remote.js"]) {
            ok = sendResponse(client, @"200 OK", @"text/javascript; charset=utf-8", embeddedFile("__remote_js"), YES);
        } else if ([path isEqualToString:@"/rr2fix/rr2fix-ca.cer"]) {
            NSData *cer = [NSData dataWithContentsOfFile:[certDir() stringByAppendingPathComponent:@"rr2fix-ca.cer"]];
            if (cer) sendResponse(client, @"200 OK", @"application/x-x509-ca-cert", cer, NO);
            else sendResponse(client, @"404 Not Found", @"text/plain", [@"No certificate yet" dataUsingEncoding:NSUTF8StringEncoding], NO);
            ok = NO;
        } else if (!secure && ([path isEqualToString:@"/"] || [path isEqualToString:@"/index.html"] ||
                               [path isEqualToString:@"/RR2Controller/"] || [path isEqualToString:@"/RR2Controller/index.html"])) {
            sendResponse(client, @"200 OK", @"text/html; charset=utf-8", embeddedFile("__remote_html"), NO);
            ok = NO;
        } else {
            ok = relayRequest(client, request, path, secure);
        }
        if (!ok) break;
    }
    [client shut];
}

#pragma mark Listeners

static BOOL startPlainListener(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {.sin_len = sizeof(addr), .sin_family = AF_INET, .sin_port = htons(REMOTE_PORT)};
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        DBG("can't listen on port %d: %s\n", REMOTE_PORT, strerror(errno));
        close(fd);
        return NO;
    }
    detach(^{
        for (;;) {
            struct sockaddr_in peer;
            socklen_t len = sizeof(peer);
            int c = accept(fd, (struct sockaddr *)&peer, &len);
            if (c < 0) {
                if (errno == EINTR || errno == ECONNABORTED) continue;
                break;
            }
            // While the game's server is closed, our own relay connections to 127.0.0.1
            // land here. Refuse them rather than relaying to ourselves.
            if (ntohl(peer.sin_addr.s_addr) >> 24 == 127) {
                close(c);
                continue;
            }
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
            setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
            RR2Stream *client = plainStream(c);
            detach(^{ serveClient(client, NO); });
        }
    });
    return YES;
}

static void startTLSListener(void) {
    sec_identity_t identity = loadIdentity();
    if (!identity) {
        DBG("no TLS certificate, so no phone steering\n");
        return;
    }
    nw_parameters_t params = nw_parameters_create_secure_tcp(^(nw_protocol_options_t tls) {
        sec_protocol_options_set_local_identity(nw_tls_copy_sec_protocol_options(tls), identity);
    }, ^(nw_protocol_options_t tcp) {
        nw_tcp_options_set_no_delay(tcp, true);
    });
    nw_parameters_set_reuse_local_address(params, true);
    static nw_listener_t listener;
    listener = nw_listener_create_with_port(REMOTE_TLS_PORT, params);
    if (!listener) return;
    dispatch_queue_t queue = dispatch_queue_create("rr2fix.remote", DISPATCH_QUEUE_CONCURRENT);
    nw_listener_set_queue(listener, queue);
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t err) {
        if (state == nw_listener_state_ready) DBG("phone controller: http://<this Mac>:%d\n", REMOTE_PORT);
        if (state == nw_listener_state_failed) DBG("TLS listener failed: %d\n", err ? nw_error_get_error_code(err) : 0);
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t conn) {
        RR2Stream *client = [RR2Stream new];
        client->fd = -1;
        client->conn = conn;
        dispatch_semaphore_t ready = dispatch_semaphore_create(0);
        __block BOOL ok = NO;
        nw_connection_set_queue(conn, queue);
        nw_connection_set_state_changed_handler(conn, ^(nw_connection_state_t state, nw_error_t err) {
            if (state == nw_connection_state_ready) ok = YES;
            if (state == nw_connection_state_ready || state == nw_connection_state_failed ||
                state == nw_connection_state_cancelled)
                dispatch_semaphore_signal(ready);
        });
        nw_connection_start(conn);
        detach(^{
            dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
            if (ok) serveClient(client, YES);
            else nw_connection_cancel(conn);
        });
    });
    nw_listener_start(listener);
}

// Starts our side of port 2011, and HTTPS in the background. Returns NO if port 2011
// is taken, in which case the game keeps its own server as it was.
static BOOL startRemoteProxy(void) {
    static BOOL started;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("RR2FIX_NO_REMOTE") || !embeddedFile("__remote_js")) return;
        started = startPlainListener();
        if (started) detach(^{ startTLSListener(); });
    });
    return started;
}

static int rr2_bind(int fd, const struct sockaddr *addr, socklen_t len) {
    Dl_info caller;
    if (addr && addr->sa_family == AF_INET && len >= sizeof(struct sockaddr_in) &&
        ((const struct sockaddr_in *)addr)->sin_port == htons(REMOTE_PORT) &&
        ((const struct sockaddr_in *)addr)->sin_addr.s_addr == htonl(INADDR_ANY) &&
        dladdr(__builtin_return_address(0), &caller) &&
        ((const struct mach_header *)caller.dli_fbase)->filetype == MH_EXECUTE &&
        startRemoteProxy()) {
        struct sockaddr_in loopback = *(const struct sockaddr_in *)addr;
        loopback.sin_len = sizeof(loopback);
        loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
        DBG("moved the game's controller server to 127.0.0.1:%d\n", REMOTE_PORT);
        return bind(fd, (struct sockaddr *)&loopback, sizeof(loopback));
    }
    return bind(fd, addr, len);
}
DYLD_INTERPOSE(rr2_bind, bind)

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
