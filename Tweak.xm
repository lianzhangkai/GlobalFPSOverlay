#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <sys/socket.h>

@interface GTFPSPassthroughWindow : UIWindow
@end

@implementation GTFPSPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return NO;
}
@end

static BOOL GTReadWiFiCounters(uint64_t *rxBytes, uint64_t *txBytes) {
    if (!rxBytes || !txBytes) return NO;

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || !interfaces) return NO;

    BOOL found = NO;
    uint64_t rx = 0;
    uint64_t tx = 0;

    for (struct ifaddrs *ifa = interfaces; ifa != NULL; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_addr || !ifa->ifa_data) continue;
        if (ifa->ifa_addr->sa_family != AF_LINK) continue;
        if (strcmp(ifa->ifa_name, "en0") != 0) continue; // iPhone/iPad Wi-Fi interface
        if ((ifa->ifa_flags & IFF_UP) == 0) continue;

        const struct if_data *data = (const struct if_data *)ifa->ifa_data;
        rx = (uint64_t)data->ifi_ibytes;
        tx = (uint64_t)data->ifi_obytes;
        found = YES;
        break;
    }

    freeifaddrs(interfaces);

    if (found) {
        *rxBytes = rx;
        *txBytes = tx;
    }
    return found;
}

static NSString *GTFormatRate(double bytesPerSecond) {
    if (!(bytesPerSecond >= 0.0)) bytesPerSecond = 0.0;

    const double KB = 1024.0;
    const double MB = 1024.0 * 1024.0;

    if (bytesPerSecond >= MB) {
        return [NSString stringWithFormat:@"%.1fM", bytesPerSecond / MB];
    }
    if (bytesPerSecond >= KB) {
        return [NSString stringWithFormat:@"%.0fK", bytesPerSecond / KB];
    }
    return [NSString stringWithFormat:@"%.0fB", bytesPerSecond];
}

@interface GTFPSOverlayController : NSObject
@property(nonatomic, strong) GTFPSPassthroughWindow *overlayWindow;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, assign) CFTimeInterval sampleStart;
@property(nonatomic, assign) NSUInteger sampleFrames;
@property(nonatomic, assign) double smoothedFPS;
@property(nonatomic, assign) BOOL started;

@property(nonatomic, assign) BOOL haveWiFiBaseline;
@property(nonatomic, assign) uint64_t lastWiFiRxBytes;
@property(nonatomic, assign) uint64_t lastWiFiTxBytes;
@property(nonatomic, assign) CFTimeInterval lastWiFiTimestamp;
@property(nonatomic, assign) double smoothedWiFiDown;
@property(nonatomic, assign) double smoothedWiFiUp;

+ (instancetype)shared;
- (void)start;
@end

@implementation GTFPSOverlayController

+ (instancetype)shared {
    static GTFPSOverlayController *obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        obj = [[GTFPSOverlayController alloc] init];
    });
    return obj;
}

- (UIWindowScene *)foregroundWindowScene API_AVAILABLE(ios(13.0)) {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive ||
            scene.activationState == UISceneActivationStateForegroundInactive) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (CGRect)currentStatusBarFrame {
    CGRect frame = CGRectZero;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = self.overlayWindow.windowScene ?: [self foregroundWindowScene];
        if (scene.statusBarManager) {
            frame = scene.statusBarManager.statusBarFrame;
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (CGRectIsEmpty(frame)) {
        frame = [UIApplication sharedApplication].statusBarFrame;
    }
#pragma clang diagnostic pop

    if (CGRectIsEmpty(frame) || CGRectGetHeight(frame) < 1.0) {
        // Full-screen apps may temporarily report a hidden status bar. Keep the
        // monitor on the physical top edge instead of moving into app content.
        frame = CGRectMake(0.0, 0.0, CGRectGetWidth([UIScreen mainScreen].bounds), 20.0);
    }
    return frame;
}

- (void)buildOverlayIfNeeded {
    if (self.overlayWindow) return;

    CGRect bounds = [UIScreen mainScreen].bounds;
    GTFPSPassthroughWindow *window = [[GTFPSPassthroughWindow alloc] initWithFrame:bounds];
    window.backgroundColor = [UIColor clearColor];
    window.windowLevel = UIWindowLevelAlert + 999.0;
    window.userInteractionEnabled = NO;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self foregroundWindowScene];
        if (scene) window.windowScene = scene;
    }

    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor clearColor];
    root.view.userInteractionEnabled = NO;
    window.rootViewController = root;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.42];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 4.0;
    label.layer.masksToBounds = YES;
    label.userInteractionEnabled = NO;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.72;
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)]) {
        label.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightSemibold];
    } else {
        label.font = [UIFont boldSystemFontOfSize:10.5];
    }
    label.text = @"FPS --/--   WiFi ↓-- ↑--";
    [root.view addSubview:label];

    self.overlayWindow = window;
    self.label = label;
    [self updateOverlayFrame];
    window.hidden = NO;
}

- (void)updateOverlayFrame {
    if (!self.overlayWindow || !self.label) return;

    CGRect bounds = [UIScreen mainScreen].bounds;
    self.overlayWindow.frame = bounds;

    CGRect statusFrame = [self currentStatusBarFrame];
    CGFloat statusHeight = MAX(18.0, CGRectGetHeight(statusFrame));
    CGFloat labelHeight = MIN(19.0, statusHeight);

    // Let the text define the width, but keep it compact enough for the iPad
    // status bar. The label is centered on the 4/5 vertical division requested
    // by the user (x = 80% of the display width).
    CGSize wanted = [self.label sizeThatFits:CGSizeMake(CGFLOAT_MAX, labelHeight)];
    CGFloat labelWidth = MIN(MAX(205.0, ceil(wanted.width + 12.0)), 285.0);

    CGFloat centerX = CGRectGetWidth(bounds) * 0.80;
    CGFloat centerY = CGRectGetMinY(statusFrame) + statusHeight * 0.50;
    if (centerY < labelHeight * 0.5) centerY = labelHeight * 0.5;

    CGFloat x = round(centerX - labelWidth * 0.5);
    CGFloat y = round(centerY - labelHeight * 0.5);

    // Clamp only to the physical display bounds; preserve the 4/5 anchor as
    // much as possible.
    x = MAX(2.0, MIN(x, CGRectGetWidth(bounds) - labelWidth - 2.0));
    y = MAX(0.0, MIN(y, CGRectGetHeight(bounds) - labelHeight));

    self.label.frame = CGRectIntegral(CGRectMake(x, y, labelWidth, labelHeight));
}

- (void)resetSampling {
    self.sampleStart = 0.0;
    self.sampleFrames = 0;
    self.smoothedFPS = 0.0;

    self.haveWiFiBaseline = NO;
    self.lastWiFiRxBytes = 0;
    self.lastWiFiTxBytes = 0;
    self.lastWiFiTimestamp = 0.0;
    self.smoothedWiFiDown = 0.0;
    self.smoothedWiFiUp = 0.0;
}

- (void)sampleWiFiAtTimestamp:(CFTimeInterval)timestamp
                   downString:(NSString * __autoreleasing *)downString
                     upString:(NSString * __autoreleasing *)upString {
    uint64_t rx = 0;
    uint64_t tx = 0;
    BOOL found = GTReadWiFiCounters(&rx, &tx);

    if (!found) {
        self.haveWiFiBaseline = NO;
        self.lastWiFiTimestamp = timestamp;
        if (downString) *downString = @"--";
        if (upString) *upString = @"--";
        return;
    }

    if (!self.haveWiFiBaseline || self.lastWiFiTimestamp <= 0.0 ||
        rx < self.lastWiFiRxBytes || tx < self.lastWiFiTxBytes) {
        self.haveWiFiBaseline = YES;
        self.lastWiFiRxBytes = rx;
        self.lastWiFiTxBytes = tx;
        self.lastWiFiTimestamp = timestamp;
        self.smoothedWiFiDown = 0.0;
        self.smoothedWiFiUp = 0.0;
        if (downString) *downString = @"0B";
        if (upString) *upString = @"0B";
        return;
    }

    CFTimeInterval dt = timestamp - self.lastWiFiTimestamp;
    if (dt <= 0.05) {
        if (downString) *downString = GTFormatRate(self.smoothedWiFiDown);
        if (upString) *upString = GTFormatRate(self.smoothedWiFiUp);
        return;
    }

    double down = (double)(rx - self.lastWiFiRxBytes) / dt;
    double up = (double)(tx - self.lastWiFiTxBytes) / dt;

    // Mild smoothing: still reacts quickly, but does not flicker wildly every
    // half second when TCP traffic is bursty.
    if (self.smoothedWiFiDown <= 0.0) self.smoothedWiFiDown = down;
    else self.smoothedWiFiDown = self.smoothedWiFiDown * 0.35 + down * 0.65;
    if (self.smoothedWiFiUp <= 0.0) self.smoothedWiFiUp = up;
    else self.smoothedWiFiUp = self.smoothedWiFiUp * 0.35 + up * 0.65;

    self.lastWiFiRxBytes = rx;
    self.lastWiFiTxBytes = tx;
    self.lastWiFiTimestamp = timestamp;

    if (downString) *downString = GTFormatRate(self.smoothedWiFiDown);
    if (upString) *upString = GTFormatRate(self.smoothedWiFiUp);
}

- (void)onDisplayLink:(CADisplayLink *)link {
    if (self.sampleStart <= 0.0) {
        self.sampleStart = link.timestamp;
        self.sampleFrames = 0;
        return;
    }

    self.sampleFrames += 1;
    CFTimeInterval elapsed = link.timestamp - self.sampleStart;
    if (elapsed < 0.50) return;

    double rawFPS = (elapsed > 0.0) ? ((double)self.sampleFrames / elapsed) : 0.0;
    if (self.smoothedFPS <= 0.0) self.smoothedFPS = rawFPS;
    else self.smoothedFPS = self.smoothedFPS * 0.65 + rawFPS * 0.35;

    NSInteger maxFPS = 60;
    UIScreen *screen = [UIScreen mainScreen];
    if ([screen respondsToSelector:@selector(maximumFramesPerSecond)]) {
        maxFPS = screen.maximumFramesPerSecond;
    }

    NSString *down = @"--";
    NSString *up = @"--";
    [self sampleWiFiAtTimestamp:link.timestamp downString:&down upString:&up];

    self.label.text = [NSString stringWithFormat:@"FPS %.0f/%ld   WiFi ↓%@ ↑%@",
                       self.smoothedFPS, (long)maxFPS, down, up];
    [self updateOverlayFrame];

    self.sampleStart = link.timestamp;
    self.sampleFrames = 0;
}

- (void)applicationDidBecomeActive:(NSNotification *)note {
    (void)note;
    [self buildOverlayIfNeeded];
    [self resetSampling];
    self.displayLink.paused = NO;
    self.overlayWindow.hidden = NO;
}

- (void)applicationWillResignActive:(NSNotification *)note {
    (void)note;
    self.displayLink.paused = YES;
    self.overlayWindow.hidden = YES;
    [self resetSampling];
}

- (void)statusBarOrOrientationChanged:(NSNotification *)note {
    (void)note;
    [self updateOverlayFrame];
}

- (void)start {
    if (self.started) return;
    self.started = YES;

    [self buildOverlayIfNeeded];

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
    if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        // 0 asks Core Animation to use its default/native cadence. We only
        // observe FPS; this tweak never forces 60/120 Hz.
        link.preferredFramesPerSecond = 0;
    }
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.displayLink = link;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [nc addObserver:self selector:@selector(statusBarOrOrientationChanged:) name:UIApplicationDidChangeStatusBarFrameNotification object:nil];
#pragma clang diagnostic pop
    [nc addObserver:self selector:@selector(statusBarOrOrientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];

    UIApplicationState state = [UIApplication sharedApplication].applicationState;
    BOOL activeEnough = (state == UIApplicationStateActive || state == UIApplicationStateInactive);
    link.paused = !activeEnough;
    self.overlayWindow.hidden = !activeEnough;
}

@end

static BOOL GTShouldLoadInCurrentProcess(void) {
    @autoreleasepool {
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath] ?: @"";
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *process = [[NSProcessInfo processInfo] processName] ?: @"";

        // Keep SpringBoard excluded. A high-level SpringBoard overlay can stay
        // above foreground apps and duplicate the app-local monitor.
        if ([bundleID isEqualToString:@"com.apple.springboard"] ||
            [process isEqualToString:@"SpringBoard"]) return NO;

        // App extensions and WebKit helper/daemon processes do not need their
        // own overlay.
        if ([bundlePath hasSuffix:@".appex"]) return NO;
        NSArray<NSString *> *blockedFragments = @[
            @"WebContent", @"Networking", @"GPU", @"SafariViewService",
            @"keyboard", @"Keyboard", @"extension", @"Extension"
        ];
        for (NSString *fragment in blockedFragments) {
            if ([process rangeOfString:fragment options:NSCaseInsensitiveSearch].location != NSNotFound) {
                return NO;
            }
        }

        Class appClass = NSClassFromString(@"UIApplication");
        if (!appClass) return NO;
        if (![appClass respondsToSelector:@selector(sharedApplication)]) return NO;
        return YES;
    }
}

%ctor {
    @autoreleasepool {
        if (!GTShouldLoadInCurrentProcess()) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            // Give the application/window scene time to finish bootstrapping.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[GTFPSOverlayController shared] start];
            });
        });
    }
}
