#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

#define AGT_DOMAIN @"com.matth.aigistoaster"
#define AGT_PREFS_NOTIF "com.matth.aigistoaster/prefs"
#define YTM_BUNDLE_ID @"com.google.ios.youtubemusic"

// ---------------------------------------------------------------------------
// MediaRemote (private), loaded dynamically
// ---------------------------------------------------------------------------
typedef void (^MRInfoBlock)(CFDictionaryRef info);
typedef void (^MRIDBlock)(CFStringRef appID);
typedef void (^MRBoolBlock)(Boolean playing);

static void (*MRRegister)(dispatch_queue_t);
static void (*MRGetInfo)(dispatch_queue_t, MRInfoBlock);
static void (*MRGetAppID)(dispatch_queue_t, MRIDBlock);
static void (*MRGetPlaying)(dispatch_queue_t, MRBoolBlock);

// ---------------------------------------------------------------------------
// Prefs
// ---------------------------------------------------------------------------
static NSUserDefaults *AGTPrefs(void) {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSUserDefaults alloc] initWithSuiteName:AGT_DOMAIN]; });
    return d;
}

static BOOL AGTBool(NSString *key, BOOL def) {
    id v = [AGTPrefs() objectForKey:key];
    return v ? [v boolValue] : def;
}

static CGFloat AGTFloat(NSString *key, CGFloat def) {
    id v = [AGTPrefs() objectForKey:key];
    return v ? [v doubleValue] : def;
}

static NSString *AGTString(NSString *key, NSString *def) {
    id v = [AGTPrefs() objectForKey:key];
    return ([v isKindOfClass:[NSString class]] && [v length]) ? v : def;
}

static UIColor *AGTColorFromHex(NSString *hex) {
    NSString *s = [[hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:s] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

// ---------------------------------------------------------------------------
// Image helpers (all safe to call off the main thread)
// ---------------------------------------------------------------------------
static UIImage *AGTDownscale(UIImage *img, CGFloat maxSide) {
    CGSize sz = img.size;
    CGFloat scale = maxSide / MAX(sz.width, sz.height);
    if (scale >= 1) return img;
    CGSize ns = CGSizeMake(round(sz.width * scale), round(sz.height * scale));
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ns format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextSetInterpolationQuality(ctx.CGContext, kCGInterpolationHigh);
        [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    }];
}

// Rendered at a decent resolution (640px) so it is never pixelated once
// stretched on screen. amount: 0-100 -> radius 0-12% of the image size.
static UIImage *AGTBlur(UIImage *img, CGFloat amount) {
    UIImage *base = AGTDownscale(img, 640);
    CIImage *ci = [CIImage imageWithCGImage:base.CGImage];
    if (!ci || amount <= 0.5) return base;
    CGFloat radius = (amount / 100.0) * 0.12 * MAX(ci.extent.size.width, ci.extent.size.height);
    CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur"];
    [f setValue:[ci imageByClampingToExtent] forKey:kCIInputImageKey];
    [f setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *out = [f.outputImage imageByCroppingToRect:ci.extent];
    static CIContext *cictx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cictx = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [cictx createCGImage:out fromRect:ci.extent];
    if (!cg) return base;
    UIImage *res = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return res;
}

// ---------------------------------------------------------------------------
// Mesh: pick a few vivid, DISTINCT colors from the artwork (keeping where they
// come from), draw big soft blobs on a dark base, once, into a small bitmap.
// ---------------------------------------------------------------------------
static UIImage *AGTRenderMesh(UIImage *art) {
    enum { N = 4 };
    uint8_t px[N * N * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs0 = CGColorSpaceCreateDeviceRGB();
    CGContextRef bc = CGBitmapContextCreate(px, N, N, 8, N * 4, cs0,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs0);
    if (!bc) return nil;
    CGContextSetInterpolationQuality(bc, kCGInterpolationHigh);
    CGContextDrawImage(bc, CGRectMake(0, 0, N, N), art.CGImage);
    CGContextRelease(bc);

    CGFloat R[N * N], G[N * N], B[N * N], score[N * N];
    CGFloat ar = 0, ag = 0, ab = 0;
    for (int i = 0; i < N * N; i++) {
        R[i] = px[i * 4] / 255.0;
        G[i] = px[i * 4 + 1] / 255.0;
        B[i] = px[i * 4 + 2] / 255.0;
        ar += R[i]; ag += G[i]; ab += B[i];
        CGFloat h, s, v, a;
        [[UIColor colorWithRed:R[i] green:G[i] blue:B[i] alpha:1] getHue:&h saturation:&s brightness:&v alpha:&a];
        score[i] = s * (0.35 + 0.65 * v) + 0.15 * v;
    }
    ar /= (N * N); ag /= (N * N); ab /= (N * N);

    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (int i = 0; i < N * N; i++) [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) {
        CGFloat a = score[x.intValue], b = score[y.intValue];
        return a < b ? NSOrderedDescending : (a > b ? NSOrderedAscending : NSOrderedSame);
    }];

    NSMutableArray<NSNumber *> *picked = [NSMutableArray array];
    for (NSNumber *n in order) {
        int i = n.intValue;
        BOOL distinct = YES;
        for (NSNumber *p in picked) {
            int j = p.intValue;
            CGFloat d = sqrt(pow(R[i] - R[j], 2) + pow(G[i] - G[j], 2) + pow(B[i] - B[j], 2));
            if (d < 0.28) { distinct = NO; break; }
        }
        if (distinct) [picked addObject:n];
        if (picked.count >= 5) break;
    }
    for (NSNumber *n in order) { // monochrome artwork: complete with the next best cells
        if (picked.count >= 4) break;
        if (![picked containsObject:n]) [picked addObject:n];
    }

    CGSize size = CGSizeMake(120, 260);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];

    return [r imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef c = rc.CGContext;
        CGContextSetRGBFillColor(c, ar * 0.45, ag * 0.45, ab * 0.45, 1);
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGFloat radius = size.height * 0.62;
        CGFloat locs[3] = {0.0, 0.5, 1.0};
        for (NSNumber *n in picked) {
            int i = n.intValue;
            CGFloat h, s, v, a;
            [[UIColor colorWithRed:R[i] green:G[i] blue:B[i] alpha:1] getHue:&h saturation:&s brightness:&v alpha:&a];
            UIColor *boosted = [UIColor colorWithHue:h saturation:MIN(1.0, s * 1.35)
                                          brightness:MAX(0.40, MIN(1.0, v * 1.1)) alpha:1];
            CGFloat cr, cg, cb;
            [boosted getRed:&cr green:&cg blue:&cb alpha:&a];
            CGFloat comps[12] = {cr, cg, cb, 0.95,
                                 cr, cg, cb, 0.45,
                                 cr, cg, cb, 0.0};
            CGGradientRef grad = CGGradientCreateWithColorComponents(cs, comps, locs, 3);
            CGPoint ctr = CGPointMake(((i % N) + 0.5) / N * size.width,
                                      ((i / N) + 0.5) / N * size.height);
            CGContextDrawRadialGradient(c, grad, ctr, 0, ctr, radius, 0);
            CGGradientRelease(grad);
        }

        // slightly darker towards the bottom (controls / readability)
        CGFloat dark[8] = {0, 0, 0, 0.0, 0, 0, 0, 0.35};
        CGGradientRef g2 = CGGradientCreateWithColorComponents(cs, dark, NULL, 2);
        CGContextDrawLinearGradient(c, g2, CGPointMake(0, size.height * 0.45), CGPointMake(0, size.height), 0);
        CGGradientRelease(g2);
        CGColorSpaceRelease(cs);
    }];
}

// ---------------------------------------------------------------------------
// Background view
// ---------------------------------------------------------------------------
@interface AGTBackgroundView : UIView
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UIImageView *imageView;   // mesh, or blurred backdrop (fills the screen)
@property (nonatomic, strong) UIImageView *frontView;   // blurred artwork, sized by the zoom setting
@property (nonatomic, strong) CAGradientLayer *frontMask;
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, copy) NSString *signature;
- (void)applyWithArtwork:(UIImage *)art artHash:(NSUInteger)hash;
@end

@implementation AGTBackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.backgroundColor = UIColor.blackColor;

        _gradientLayer = [CAGradientLayer layer];
        _gradientLayer.frame = self.bounds;
        _gradientLayer.hidden = YES;
        [self.layer addSublayer:_gradientLayer];

        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _imageView.hidden = YES;
        [self addSubview:_imageView];

        _frontView = [[UIImageView alloc] initWithFrame:self.bounds];
        _frontView.contentMode = UIViewContentModeScaleToFill;
        _frontView.hidden = YES;
        _frontView.layer.shouldRasterize = YES;
        _frontView.layer.rasterizationScale = UIScreen.mainScreen.scale;
        [self addSubview:_frontView];

        _frontMask = [CAGradientLayer layer];
        _frontMask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor,
                              (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
        _frontMask.locations = @[@0.0, @0.3, @0.7, @1.0];
        _frontMask.startPoint = CGPointMake(0.5, 0);
        _frontMask.endPoint = CGPointMake(0.5, 1);

        _dimView = [[UIView alloc] initWithFrame:self.bounds];
        _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dimView.backgroundColor = UIColor.blackColor;
        [self addSubview:_dimView];
    }
    return self;
}

- (void)layoutFront {
    UIImage *img = self.frontView.image;
    if (!img || self.bounds.size.width <= 0) return;
    CGFloat zoom = MAX(1.0, AGTFloat(@"blurZoom", 1.0));
    CGFloat aspect = img.size.width / MAX(1.0, img.size.height);
    CGFloat w = self.bounds.size.width * zoom;
    CGFloat h = w / aspect;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.frontView.frame = CGRectMake((self.bounds.size.width - w) / 2, (self.bounds.size.height - h) / 2, w, h);
    self.frontMask.frame = self.frontView.bounds;
    self.frontView.layer.mask = (h >= self.bounds.size.height) ? nil : self.frontMask;
    [CATransaction commit];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.gradientLayer.frame = self.bounds;
    [CATransaction commit];
    if (!self.frontView.hidden) [self layoutFront];
}

- (void)showImage:(UIImage *)img blur:(BOOL)isBlur animated:(BOOL)animated {
    self.imageView.image = img;
    self.imageView.hidden = NO;
    self.gradientLayer.hidden = YES;
    [self.imageView.layer removeAnimationForKey:@"drift"];

    if (isBlur) {
        self.frontView.image = img;
        self.frontView.hidden = NO;
        [self layoutFront];
    } else {
        self.frontView.hidden = YES;
        self.frontView.image = nil;
    }

    if (animated) {
        // One single layer, one slow transform: very cheap compared to many live gradients.
        CABasicAnimation *an = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
        an.fromValue = @1.0;
        an.toValue = @1.2;
        an.duration = 20.0;
        an.autoreverses = YES;
        an.repeatCount = HUGE_VALF;
        an.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.imageView.layer addAnimation:an forKey:@"drift"];
    }
}

- (void)applyWithArtwork:(UIImage *)art artHash:(NSUInteger)hash {
    NSString *mode = AGTString(@"mode", @"mesh"); // gradient | mesh | blur
    if (!art && ![mode isEqualToString:@"gradient"]) mode = @"gradient";

    CGFloat dim = AGTFloat(@"dim", 0.25);
    NSString *c1 = AGTString(@"gradientColor1", @"#FF0050");
    NSString *c2 = AGTString(@"gradientColor2", @"#7000FF");
    CGFloat angle = AGTFloat(@"gradientAngle", 135);
    CGFloat blur = AGTFloat(@"blurAmount", 60);
    CGFloat zoom = AGTFloat(@"blurZoom", 1.0);
    BOOL anim = AGTBool(@"meshAnimated", NO);
    BOOL isGradient = [mode isEqualToString:@"gradient"];

    NSString *sig = [NSString stringWithFormat:@"%@|%.2f|%@|%@|%.0f|%.0f|%.2f|%d|%lu",
                     mode, dim, c1, c2, angle, blur, zoom, anim, (unsigned long)(isGradient ? 0 : hash)];
    if ([sig isEqualToString:self.signature]) return; // nothing changed: do no work at all
    self.signature = sig;
    self.dimView.alpha = dim;

    if (isGradient) {
        CGFloat rad = angle * M_PI / 180.0;
        self.gradientLayer.colors = @[(id)AGTColorFromHex(c1).CGColor, (id)AGTColorFromHex(c2).CGColor];
        self.gradientLayer.startPoint = CGPointMake(0.5 - cos(rad) / 2, 0.5 - sin(rad) / 2);
        self.gradientLayer.endPoint = CGPointMake(0.5 + cos(rad) / 2, 0.5 + sin(rad) / 2);
        self.gradientLayer.hidden = NO;
        self.imageView.hidden = YES;
        self.frontView.hidden = YES;
        [self.imageView.layer removeAnimationForKey:@"drift"];
        return;
    }

    BOOL isBlur = [mode isEqualToString:@"blur"];
    __weak AGTBackgroundView *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        UIImage *result = isBlur ? AGTBlur(art, blur) : AGTRenderMesh(art);
        dispatch_async(dispatch_get_main_queue(), ^{
            AGTBackgroundView *s = weakSelf;
            if (!s || !result || ![s.signature isEqualToString:sig]) return; // outdated
            [s showImage:result blur:isBlur animated:(!isBlur && anim)];
        });
    });
}

@end

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static AGTBackgroundView *gView;
static UIImage *gArt;
static NSUInteger gArtHash;
static BOOL gActive;
static BOOL gVisible;
static NSUInteger gGen;

static void AGTPresent(void) {
    if (!gView) return;
    BOOL on = gActive && AGTBool(@"enabled", YES);
    if (on && gVisible) [gView applyWithArtwork:gArt artHash:gArtHash];
    CGFloat target = on ? 1.0 : 0.0;
    if (gView.alpha != target) {
        [UIView animateWithDuration:0.6 animations:^{ gView.alpha = target; }];
    }
}

static void AGTSetActive(BOOL on) {
    gActive = on;
    AGTPresent();
}

static void AGTRefresh(void) {
    if (!gVisible) return; // lockscreen not shown: do nothing (refreshed on next appear)
    if (!MRGetAppID || !MRGetPlaying || !MRGetInfo) return;
    if (!AGTBool(@"enabled", YES)) { AGTSetActive(NO); return; }

    dispatch_queue_t q = dispatch_get_main_queue();
    MRGetAppID(q, ^(CFStringRef appID) {
        NSString *bid = (__bridge NSString *)appID;
        if (AGTBool(@"onlyYTMusic", YES) && ![bid isEqualToString:YTM_BUNDLE_ID]) {
            AGTSetActive(NO);
            return;
        }
        MRGetPlaying(q, ^(Boolean playing) {
            if (!playing) {
                AGTSetActive(NO);
                return;
            }
            MRGetInfo(q, ^(CFDictionaryRef info) {
                NSDictionary *d = (__bridge NSDictionary *)info;
                NSData *data = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                NSUInteger h = data ? (data.length * 31u + data.hash) : 0;
                if (h != gArtHash || (!gArt && data)) { // only decode when the artwork really changed
                    gArt = data ? [UIImage imageWithData:data] : nil;
                    gArtHash = h;
                }
                AGTSetActive(YES);
            });
        });
    });
}

// MediaRemote fires a lot of notifications (elapsed time, etc.): coalesce them.
static void AGTScheduleRefresh(void) {
    NSUInteger gen = ++gGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen == gGen) AGTRefresh();
    });
}

static void AGTPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!AGTBool(@"enabled", YES)) { AGTSetActive(NO); return; }
        AGTScheduleRefresh();
        AGTPresent();
    });
}

static void AGTAttach(UIView *host) {
    if (!host) return;
    if (gView && gView.superview == host) return;
    [gView removeFromSuperview];
    gView = [[AGTBackgroundView alloc] initWithFrame:host.bounds];
    gView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gView.alpha = 0;
    [host insertSubview:gView atIndex:0];
    AGTPresent();
}

// ---------------------------------------------------------------------------
// Hook
// ---------------------------------------------------------------------------
@interface CSCoverSheetViewController : UIViewController
@end

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    AGTAttach(self.view);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    gVisible = YES;
    AGTAttach(self.view);
    AGTRefresh();
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    gVisible = NO;
}

%end

%ctor {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!h) return;
    MRRegister = (void (*)(dispatch_queue_t))dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    MRGetInfo = (void (*)(dispatch_queue_t, MRInfoBlock))dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    MRGetAppID = (void (*)(dispatch_queue_t, MRIDBlock))dlsym(h, "MRMediaRemoteGetNowPlayingApplicationDisplayID");
    MRGetPlaying = (void (*)(dispatch_queue_t, MRBoolBlock))dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");

    if (MRRegister) MRRegister(dispatch_get_main_queue());

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            AGTScheduleRefresh();
        }];
    }

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, AGTPrefsChanged,
                                    CFSTR(AGT_PREFS_NOTIF), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
