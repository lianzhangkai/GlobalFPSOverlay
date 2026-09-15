#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

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

@interface GTFPSOverlayController : NSObject
@property(nonatomic, strong) GTFPSPassthroughWindow *overlayWindow;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, assign) CFTimeInterval sampleStart;
@property(nonatomic, assign) NSUInteger sampleFrames;
@property(nonatomic, assign) double smoothedFPS;
@property(nonatomic, assign) BOOL started;
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
    label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.58];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 6.0;
    label.layer.masksToBounds = YES;
    label.userInteractionEnabled = NO;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    if ([UIFont respondsToSelector:@selector(monospacedDigitSystemFontOfSize:weight:)]) {
        label.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightSemibold];
    } else {
        label.font = [UIFont boldSystemFontOfSize:12.0];
    }
    label.text = @"FPS -- | MAX --";
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

    CGFloat width = 128.0;
    CGFloat height = 26.0;
    CGFloat margin = 8.0;
    CGFloat safeTop = 0.0;
    CGFloat safeRight = 0.0;

    if (@available(iOS 11.0, *)) {
        UIEdgeInsets insets = self.overlayWindow.safeAreaInsets;
        safeTop = insets.top;
        safeRight = insets.right;
    }

    CGFloat x = CGRectGetWidth(bounds) - safeRight - width - margin;
    CGFloat y = MAX(safeTop + 4.0, margin);
    self.label.frame = CGRectIntegral(CGRectMake(x, y, width, height));
}

- (void)resetSampling {
    self.sampleStart = 0.0;
    self.sampleFrames = 0;
    self.smoothedFPS = 0.0;
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

    self.label.text = [NSString stringWithFormat:@"FPS %.1f | MAX %ld", self.smoothedFPS, (long)maxFPS];
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

- (void)start {
    if (self.started) return;
    self.started = YES;

    [self buildOverlayIfNeeded];

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayLink:)];
    if ([link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) {
        // 0 asks Core Animation to use its default/native cadence.  We do not force 60 or 120.
        link.preferredFramesPerSecond = 0;
    }
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.displayLink = link;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];

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

        // SpringBoard owns a system-level window. If we create our high-level FPS window there,
        // it can remain visible above foreground apps and duplicate the app-local overlay.
        // For accurate per-app FPS, do not inject an overlay into SpringBoard.
        if ([bundleID isEqualToString:@"com.apple.springboard"] ||
            [process isEqualToString:@"SpringBoard"]) return NO;

        // App extensions and WebKit helper/daemon processes do not need their own overlay.
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
