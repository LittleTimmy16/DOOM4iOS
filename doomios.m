// doomios.m  (v2)
// Touch-screen platform layer for doomgeneric on iOS (built with FCM).
// New in v2:
//   - Drag a finger on the game screen to look left/right
//   - EDIT button: move and resize the on-screen buttons, saved between launches
// Needs doomlook.c in the project too.

#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <unistd.h>
#include "doomgeneric.h"
#include "doomkeys.h"

void DoomLookPost(int dx);   // defined in doomlook.c
void DoomAudioFill(int16_t *out, int frames);   // defined in doomsound.c

// DEBUG: writes progress notes to Documents/boot.txt
static void Crumb(NSString *s) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *p = [docs stringByAppendingPathComponent:@"boot.txt"];
    NSString *line = [s stringByAppendingString:@"\n"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!h) { [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; return; }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

// DEBUG: record why the app died
static void DoomExceptionHandler(NSException *e) {
    Crumb([NSString stringWithFormat:@"EXCEPTION %@: %@\n%@", e.name, e.reason, e.callStackSymbols]);
}
static void DoomSignalHandler(int sig) {
    Crumb([NSString stringWithFormat:@"SIGNAL %d", sig]);
    signal(sig, SIG_DFL);
    raise(sig);
}

#define LOOK_SENS 6.0f       // bigger = faster turning when you drag

// ---------------------------------------------------------------
#pragma mark - Key queue (touch buttons -> game thread)
// ---------------------------------------------------------------

#define QSIZE 64
static unsigned short keyQueue[QSIZE];
static int qHead = 0, qTail = 0;
static pthread_mutex_t qMutex = PTHREAD_MUTEX_INITIALIZER;

static volatile int lookAccum = 0;   // finger-drag turning, read by the game thread

static void PushKey(int pressed, unsigned char key) {
    pthread_mutex_lock(&qMutex);
    int next = (qHead + 1) % QSIZE;
    if (next != qTail) {
        keyQueue[qHead] = (unsigned short)((pressed << 8) | key);
        qHead = next;
    }
    pthread_mutex_unlock(&qMutex);
}

// ---------------------------------------------------------------
#pragma mark - UI
// ---------------------------------------------------------------

static UIView *gameView = nil;
static CGContextRef frameCtx = NULL;
static volatile int framePending = 0;

@interface DoomButton : UIButton
@property (nonatomic) CGFloat cx, cy, size;           // center as fraction of screen, size in points
@property (nonatomic) CGFloat defCx, defCy, defSize;  // factory defaults
@property (nonatomic, strong) UIPanGestureRecognizer *pan;
@end
@implementation DoomButton
@end

static UIButton *MakeCtrl(NSString *title, CGRect f) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = f;
    b.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 1;
    b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    return b;
}

@interface DoomOverlay : UIView
@end

@implementation DoomOverlay {
    NSMutableArray<DoomButton *> *btns;
    BOOL editMode;
    DoomButton *selected;
    UIView *editPanel;
    UIButton *editBtn;
    UITouch *lookTouch;
    CGPoint lastPt;
    float lookFrac;
    CGSize lastLayoutSize;
}

// ----- game keys -----

- (void)keyDown:(DoomButton *)b {
    if (editMode) { [self select:b]; return; }
    PushKey(1, (unsigned char)b.tag);
}

- (void)keyUp:(DoomButton *)b {
    if (editMode) return;
    PushKey(0, (unsigned char)b.tag);
}

// ----- building the buttons -----

- (void)addButton:(NSString *)title key:(int)key center:(CGPoint)c size:(CGFloat)s {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    DoomButton *b = [DoomButton buttonWithType:UIButtonTypeCustom];
    b.tag = key;
    b.cx = b.defCx = c.x / W;
    b.cy = b.defCy = c.y / H;
    b.size = b.defSize = s;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    b.layer.borderWidth = 1.5;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [b addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:@selector(keyUp:)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];

    // dragging only works in edit mode
    b.pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panButton:)];
    b.pan.enabled = NO;
    [b addGestureRecognizer:b.pan];

    [self addSubview:b];
    [btns addObject:b];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    btns = [[NSMutableArray alloc] init];   // explicit alloc so it stays alive without ARC
    self.backgroundColor = [UIColor blackColor];
    self.multipleTouchEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    gameView = [[UIView alloc] initWithFrame:self.bounds];
    gameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gameView.layer.contentsGravity = kCAGravityResizeAspect;
    gameView.layer.magnificationFilter = kCAFilterNearest;
    gameView.userInteractionEnabled = NO;
    [self addSubview:gameView];

    CGFloat W = frame.size.width, H = frame.size.height;
    CGFloat s = 64, g = 8, m = 24;

    // D-pad (bottom-left)
    CGPoint P = CGPointMake(m + 1.5 * s + g, H - m - 1.5 * s - g);
    [self addButton:@"UP"    key:KEY_UPARROW    center:CGPointMake(P.x, P.y - (s + g)) size:s];
    [self addButton:@"DOWN"  key:KEY_DOWNARROW  center:CGPointMake(P.x, P.y + (s + g)) size:s];
    [self addButton:@"LEFT"  key:KEY_LEFTARROW  center:CGPointMake(P.x - (s + g), P.y) size:s];
    [self addButton:@"RIGHT" key:KEY_RIGHTARROW center:CGPointMake(P.x + (s + g), P.y) size:s];

    // Action buttons (bottom-right)
    [self addButton:@"FIRE" key:KEY_FIRE   center:CGPointMake(W - m - 0.5 * s,       H - m - 1.5 * s - g)     size:s];
    [self addButton:@"USE"  key:KEY_USE    center:CGPointMake(W - m - 1.5 * s - g,   H - m - 0.5 * s)         size:s];
    [self addButton:@"RUN"  key:KEY_RSHIFT center:CGPointMake(W - m - 1.5 * s - g,   H - m - 1.5 * s - 2 * g) size:s];

    // Menu buttons (top-right)
    [self addButton:@"MENU" key:KEY_ESCAPE center:CGPointMake(W - m - 0.5 * s,     m + 20 + 0.5 * s) size:s];
    [self addButton:@"OK"   key:KEY_ENTER  center:CGPointMake(W - m - 1.5 * s - g, m + 20 + 0.5 * s) size:s];

    [self loadLayout];

    // EDIT button (top-left)
    editBtn = MakeCtrl(@"EDIT", CGRectMake(m, m + 20, 60, 36));
    [editBtn addTarget:self action:@selector(enterEdit) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:editBtn];

    // Edit panel (shown only in edit mode)
    editPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 78)];
    editPanel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    editPanel.layer.cornerRadius = 10;
    editPanel.hidden = YES;
    NSArray *titles = @[@"-", @"+", @"RESET", @"DONE"];
    SEL sels[4] = { @selector(smaller), @selector(bigger), @selector(resetLayout), @selector(exitEdit) };
    for (int i = 0; i < 4; i++) {
        UIButton *c = MakeCtrl(titles[i], CGRectMake(8 + i * 88, 8, 80, 40));
        [c addTarget:self action:sels[i] forControlEvents:UIControlEventTouchUpInside];
        [editPanel addSubview:c];
    }
    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(8, 50, 344, 22)];
    hint.text = @"Drag a button to move it. Tap it, then - or +.";
    hint.textColor = [UIColor whiteColor];
    hint.font = [UIFont systemFontOfSize:12];
    hint.textAlignment = NSTextAlignmentCenter;
    [editPanel addSubview:hint];
    [self addSubview:editPanel];

    lastLayoutSize = self.bounds.size;
    [self applyLayout];

    return self;
}

// ----- layout (positions are stored as fractions, so rotation is fine) -----

- (void)applyLayout {
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    for (DoomButton *b in btns) {
        CGRect nb = CGRectMake(0, 0, b.size, b.size);
        CGPoint nc = CGPointMake(b.cx * W, b.cy * H);
        if (!CGRectEqualToRect(b.bounds, nb)) {
            b.bounds = nb;
            b.layer.cornerRadius = b.size / 2.0;
        }
        if (!CGPointEqualToPoint(b.center, nc)) b.center = nc;
    }
    CGPoint pc = CGPointMake(W / 2.0, 79);
    if (!CGPointEqualToPoint(editPanel.center, pc)) editPanel.center = pc;
}

// Only re-layout when the screen size really changed (prevents layout loops)
- (void)layoutSubviews {
    [super layoutSubviews];
    if (CGSizeEqualToSize(self.bounds.size, lastLayoutSize)) return;
    lastLayoutSize = self.bounds.size;
    [self applyLayout];
}

// ----- saving and loading -----

- (void)saveLayout {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (DoomButton *b in btns)
        d[[NSString stringWithFormat:@"%ld", (long)b.tag]] = @[@(b.cx), @(b.cy), @(b.size)];
    [[NSUserDefaults standardUserDefaults] setObject:d forKey:@"doomLayout"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)loadLayout {
    NSDictionary *d = [[NSUserDefaults standardUserDefaults] objectForKey:@"doomLayout"];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    for (DoomButton *b in btns) {
        NSArray *a = d[[NSString stringWithFormat:@"%ld", (long)b.tag]];
        if ([a isKindOfClass:[NSArray class]] && a.count == 3) {
            b.cx = [a[0] floatValue];
            b.cy = [a[1] floatValue];
            b.size = [a[2] floatValue];
        }
    }
}

// ----- edit mode -----

- (void)select:(DoomButton *)b {
    if (selected) selected.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    selected = b;
    b.layer.borderColor = [UIColor yellowColor].CGColor;
}

- (void)enterEdit {
    Crumb(@"edit: enterEdit start");
    editMode = YES;
    editPanel.hidden = NO;
    editBtn.hidden = YES;
    Crumb(@"edit: panel shown");
    for (DoomButton *b in btns) b.pan.enabled = YES;
    Crumb(@"edit: enterEdit done");
}

- (void)exitEdit {
    editMode = NO;
    editPanel.hidden = YES;
    editBtn.hidden = NO;
    for (DoomButton *b in btns) b.pan.enabled = NO;
    if (selected) selected.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    selected = nil;
    [self saveLayout];
}

- (void)panButton:(UIPanGestureRecognizer *)g {
    if (!editMode) return;
    DoomButton *b = (DoomButton *)g.view;
    if (g.state == UIGestureRecognizerStateBegan) [self select:b];
    CGPoint t = [g translationInView:self];
    [g setTranslation:CGPointZero inView:self];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    b.cx = MAX(0.03, MIN(0.97, b.cx + t.x / W));
    b.cy = MAX(0.03, MIN(0.97, b.cy + t.y / H));
    [self applyLayout];
}

- (void)bigger {
    if (!selected) return;
    selected.size = MIN(140, selected.size + 8);
    [self applyLayout];
}

- (void)smaller {
    if (!selected) return;
    selected.size = MAX(40, selected.size - 8);
    [self applyLayout];
}

- (void)resetLayout {
    for (DoomButton *b in btns) { b.cx = b.defCx; b.cy = b.defCy; b.size = b.defSize; }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"doomLayout"];
    [self applyLayout];
}

// ----- drag on the game screen to look -----

- (void)flushLook {
    int v = (int)lookFrac;
    if (v == 0) return;
    lookFrac -= v;
    __sync_fetch_and_add(&lookAccum, v);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (editMode || lookTouch) return;
    lookTouch = touches.anyObject;
    lastPt = [lookTouch locationInView:self];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (editMode || !lookTouch || ![touches containsObject:lookTouch]) return;
    CGPoint p = [lookTouch locationInView:self];
    lookFrac += (p.x - lastPt.x) * LOOK_SENS;
    lastPt = p;
    [self flushLook];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (lookTouch && [touches containsObject:lookTouch]) lookTouch = nil;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (lookTouch && [touches containsObject:lookTouch]) lookTouch = nil;
}

@end

// ---------------------------------------------------------------
#pragma mark - Starting the engine
// ---------------------------------------------------------------

static void ShowError(UIView *host, NSString *msg) {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectInset(host.bounds, 20, 20)];
    l.text = msg;
    l.textColor = [UIColor whiteColor];
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:l];
}

static NSString *FindWad(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSArray *dirs = @[ [[NSBundle mainBundle] bundlePath], docs ];
    for (NSString *dir in dirs) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            if ([f.pathExtension caseInsensitiveCompare:@"wad"] == NSOrderedSame)
                return [dir stringByAppendingPathComponent:f];
        }
    }
    return nil;
}

static void StartDoom(UIView *host) {
    NSString *wad = FindWad();
    Crumb(wad ? @"5 wad found" : @"5 NO wad");
    if (!wad) {
        ShowError(host, @"No .wad file found.\nPut doom1.wad in the project folder or the app's Documents folder.");
        return;
    }

    NSThread *t = [[NSThread alloc] initWithBlock:^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        chdir(docs.fileSystemRepresentation);

        char *argv[] = { "doom", "-iwad", (char *)wad.fileSystemRepresentation, NULL };
        Crumb(@"6 starting engine");
        doomgeneric_Create(3, argv);
        for (;;) doomgeneric_Tick();
    }];
    t.stackSize = 8 * 1024 * 1024;
    t.name = @"doom";
    [t start];
}

static void AttachToWindow(void) {
    static BOOL done = NO;
    if (done) return;

    UIWindow *win = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if ([sc isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
        }
        if (win) break;
    }
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    Crumb(win ? @"3 window found" : @"3 NO window found");
    if (!win) return;

    done = YES;
    DoomOverlay *overlay = [[DoomOverlay alloc] initWithFrame:win.bounds];
    Crumb(@"4 overlay created");
    [win addSubview:overlay];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        Crumb([NSString stringWithFormat:@"9 overlay frame=%@ superview=%@ hidden=%d alpha=%.2f subviews=%lu",
               NSStringFromCGRect(overlay.frame), NSStringFromClass([overlay.superview class]),
               overlay.hidden, overlay.alpha, (unsigned long)overlay.subviews.count]);
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                Crumb([NSString stringWithFormat:@"10 window %@ level=%.0f hidden=%d key=%d subviews=%lu isOurs=%d",
                       NSStringFromClass([w class]), w.windowLevel, w.hidden, w.isKeyWindow,
                       (unsigned long)w.subviews.count, w == win]);
            }
        }
    });
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    StartDoom(overlay);
}

__attribute__((constructor))
static void DoomBoot(void) {
    Crumb(@"1 constructor ran");
    NSSetUncaughtExceptionHandler(&DoomExceptionHandler);
    signal(SIGSEGV, DoomSignalHandler);
    signal(SIGABRT, DoomSignalHandler);
    signal(SIGBUS,  DoomSignalHandler);
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:[NSOperationQueue mainQueue]
        usingBlock:^(NSNotification *n) {
            Crumb(@"2 app became active");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ AttachToWindow(); });
        }];
}

// ---------------------------------------------------------------
#pragma mark - doomgeneric platform functions
// ---------------------------------------------------------------

// ---------------------------------------------------------------
#pragma mark - Audio output (sound effects come from doomsound.c)
// ---------------------------------------------------------------

#define AUDIO_RATE   44100
#define AUDIO_FRAMES 512

static AudioQueueRef audioQueue = NULL;

static void AudioCallback(void *user, AudioQueueRef q, AudioQueueBufferRef buf) {
    DoomAudioFill((int16_t *)buf->mAudioData, AUDIO_FRAMES);
    buf->mAudioDataByteSize = AUDIO_FRAMES * 4;   // 2 channels x 16-bit
    AudioQueueEnqueueBuffer(q, buf, 0, NULL);
}

// Called by doomsound.c when Doom starts its sound system
void DoomAudioStart(int rate) {
    if (audioQueue) return;

    AVAudioSession *sess = [AVAudioSession sharedInstance];
    [sess setCategory:AVAudioSessionCategoryPlayback error:nil];
    [sess setActive:YES error:nil];

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate       = AUDIO_RATE;
    fmt.mFormatID         = kAudioFormatLinearPCM;
    fmt.mFormatFlags      = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    fmt.mChannelsPerFrame = 2;
    fmt.mBitsPerChannel   = 16;
    fmt.mBytesPerFrame    = 4;
    fmt.mFramesPerPacket  = 1;
    fmt.mBytesPerPacket   = 4;

    if (AudioQueueNewOutput(&fmt, AudioCallback, NULL, NULL, NULL, 0, &audioQueue) != noErr) {
        audioQueue = NULL;
        Crumb(@"audio: AudioQueueNewOutput failed");
        return;
    }
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buf;
        AudioQueueAllocateBuffer(audioQueue, AUDIO_FRAMES * 4, &buf);
        AudioCallback(NULL, audioQueue, buf);   // fill and enqueue
    }
    AudioQueueStart(audioQueue, NULL);
    Crumb(@"audio: started");
}

void DG_Init(void) {
    Crumb(@"7 DG_Init");
}

void DG_DrawFrame(void) {
    if (!gameView || !DG_ScreenBuffer) return;

    if (!frameCtx) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        frameCtx = CGBitmapContextCreate(DG_ScreenBuffer,
                                         DOOMGENERIC_RESX, DOOMGENERIC_RESY, 8,
                                         DOOMGENERIC_RESX * 4, cs,
                                         kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(cs);
        if (!frameCtx) return;
    }

    static int firstFrame = 1;
    if (firstFrame) { firstFrame = 0; Crumb(@"8 first frame drawn"); }
    if (framePending) return;
    framePending = 1;

    CGImageRef img = CGBitmapContextCreateImage(frameCtx);
    dispatch_async(dispatch_get_main_queue(), ^{
        gameView.layer.contents = (__bridge id)img;
        CGImageRelease(img);
        framePending = 0;
    });
}

void DG_SleepMs(uint32_t ms) {
    usleep(ms * 1000);
}

uint32_t DG_GetTicksMs(void) {
    return (uint32_t)(CACurrentMediaTime() * 1000.0);
}

int DG_GetKey(int *pressed, unsigned char *doomKey) {
    // hand any finger-drag turning to the engine (runs on the game thread)
    int d = __sync_lock_test_and_set(&lookAccum, 0);
    if (d) DoomLookPost(d);

    int got = 0;
    pthread_mutex_lock(&qMutex);
    if (qTail != qHead) {
        unsigned short e = keyQueue[qTail];
        qTail = (qTail + 1) % QSIZE;
        *pressed = e >> 8;
        *doomKey = (unsigned char)(e & 0xff);
        got = 1;
    }
    pthread_mutex_unlock(&qMutex);
    return got;
}

void DG_SetWindowTitle(const char *title) {
}
