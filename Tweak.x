#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

#define AGT_DOMAIN @"com.matth.aigistoaster"
#define AGT_PREFS_NOTIF "com.matth.aigistoaster/prefs"
#define YTM_BUNDLE_ID @"com.google.ios.youtubemusic"

// ---------------------------------------------------------------------------
// MediaRemote (private) loaded dynamically
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
    return [v isKindOfClass:[NSString class]] ? v : def;
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
// Image helpers
// ---------------------------------------------------------------------------
static UIImage *AGTDownscale(UIImage *img, CGFloat maxSide) {
    CGSize sz = img.size;
    CGFloat scale = maxSide / MAX(sz.width, sz.height);
    if (scale >= 1) return img;
    CGSize ns = CGSizeMake(sz.width * scale, sz.height * scale);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:ns format:fmt];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [img drawInRect:CGRectMake(0, 0, ns.width, ns.height)];
    }];
}

static UIImage *AGTBlur(UIImage *img, CGFloat amount) {
    UIImage *small = AGTDownscale(img, 160);
    CIImage *ci = [CIImage imageWithCGImage:small.CGImage];
    if (!ci) return img;
    CIFilter *f = [CIFilter filterWithName:@"CIGaussianBlur"];
    [f setValue:[ci imageByClampingToExtent] forKey:kCIInputImageKey];
    [f setValue:@(amount * 0.25) forKey:kCIInputRadiusKey]; // amount 0-100 -> radius 0-25
    CIImage *out = [f.outputImage imageByCroppingToRect:ci.extent];
    static CIContext *cictx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cictx = [CIContext contextWithOptions:nil]; });
    CGImageRef cg = [cictx createCGImage:out fromRect:ci.extent];
    if (!cg) return img;
    UIImage *res = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return res;
}

// Samples a 3x3 grid of colors (row-major, top-left first).
static NSArray<UIColor *> *AGTSampleGrid(UIImage *img) {
    enum { N = 3 };
    uint8_t px[N * N * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, N, N, 8, N * 4, cs,
                                           kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!c) return nil;
    CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
    CGContextDrawImage(c, CGRectMake(0, 0, N, N), img.CGImage);
    CGContextRelease(c);

    NSMutableArray *colors = [NSMutableArray array];
    for (int i = 0; i < N * N; i++) {
        UIColor *raw = [UIColor colorWithRed:px[i * 4] / 255.0
                                       green:px[i * 4 + 1] / 255.0
                                        blue:px[i * 4 + 2] / 255.0
                                       alpha:1];
        CGFloat h, s, b, a;
        [raw getHue:&h saturation:&s brightness:&b alpha:&a];
        s = MIN(1.0, s * 1.3);
        b = MAX(0.25, MIN(0.95, b));
        [colors addObject:[UIColor colorWithHue:h saturation:s brightness:b alpha:1]];
    }
    return colors;
}

// ---------------------------------------------------------------------------
// Background view
// ---------------------------------------------------------------------------
@interface AGTBackgroundView : UIView
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIView *meshContainer;
@property (nonatomic, strong) UIView *dimView;
- (void)applyWithArtwork:(UIImage *)art;
@end

@implementation AGTBackgroundView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.backgroundColor = UIColor.blackColor;

        _gradientLayer = [CAGradientLayer layer];
        _gradientLayer.frame = self.bounds;
        [self.layer addSublayer:_gradientLayer];

        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_imageView];

        _meshContainer = [[UIView alloc] initWithFrame:self.bounds];
        _meshContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_meshContainer];

        _dimView = [[UIView alloc] initWithFrame:self.bounds];
        _dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _dimView.backgroundColor = UIColor.blackColor;
        [self addSubview:_dimView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.gradientLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)applyWithArtwork:(UIImage *)art {
    NSString *mode = AGTString(@"mode", @"mesh"); // gradient | mesh | blur
    if (!art && ![mode isEqualToString:@"gradient"]) mode = @"gradient";

    self.gradientLayer.hidden = YES;
    self.imageView.hidden = YES;
    self.meshContainer.hidden = YES;
    [self.meshContainer.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
    self.dimView.alpha = AGTFloat(@"dim", 0.25);

    if ([mode isEqualToString:@"gradient"]) {
        NSString *list = AGTString(@"gradientColors", @"#FF0050,#7000FF");
        NSMutableArray *cgColors = [NSMutableArray array];
        for (NSString *hex in [list componentsSeparatedByString:@","]) {
            if (hex.length) [cgColors addObject:(id)AGTColorFromHex(hex).CGColor];
        }
        if (cgColors.count < 2) {
            cgColors = [NSMutableArray arrayWithObjects:(id)AGTColorFromHex(@"#FF0050").CGColor,
                                                       (id)AGTColorFromHex(@"#7000FF").CGColor, nil];
        }
        CGFloat rad = AGTFloat(@"gradientAngle", 135) * M_PI / 180.0;
        self.gradientLayer.colors = cgColors;
        self.gradientLayer.startPoint = CGPointMake(0.5 - cos(rad) / 2, 0.5 - sin(rad) / 2);
        self.gradientLayer.endPoint = CGPointMake(0.5 + cos(rad) / 2, 0.5 + sin(rad) / 2);
        self.gradientLayer.hidden = NO;
        return;
    }

    if ([mode isEqualToString:@"blur"]) {
        self.imageView.image = AGTBlur(art, AGTFloat(@"blurAmount", 60));
        self.imageView.hidden = NO;
        return;
    }

    // mesh
    NSArray<UIColor *> *colors = AGTSampleGrid(art);
    if (colors.count != 9) return;

    CGRect b = self.bounds;
    if (CGRectIsEmpty(b)) b = UIScreen.mainScreen.bounds;

    CGFloat r = 0, g = 0, bl = 0, a;
    for (UIColor *c in colors) {
        CGFloat cr, cg, cb;
        [c getRed:&cr green:&cg blue:&cb alpha:&a];
        r += cr; g += cg; bl += cb;
    }
    self.meshContainer.backgroundColor = [UIColor colorWithRed:r / 9 green:g / 9 blue:bl / 9 alpha:1];
    self.meshContainer.frame = b;

    CGFloat diameter = MAX(b.size.width, b.size.height) * 0.75;
    for (int i = 0; i < 9; i++) {
        int col = i % 3, row = i / 3;
        CGPoint center = CGPointMake((col + 0.5) / 3.0 * b.size.width,
                                     (row + 0.5) / 3.0 * b.size.height);
        CAGradientLayer *blob = [CAGradientLayer layer];
        blob.type = kCAGradientLayerRadial;
        blob.colors = @[(id)colors[i].CGColor, (id)[colors[i] colorWithAlphaComponent:0].CGColor];
        blob.startPoint = CGPointMake(0.5, 0.5);
        blob.endPoint = CGPointMake(1, 1);
        blob.bounds = CGRectMake(0, 0, diameter, diameter);
        blob.position = center;
        [self.meshContainer.layer addSublayer:blob];

        if (AGTBool(@"meshAnimated", YES)) {
            CABasicAnimation *an = [CABasicAnimation animationWithKeyPath:@"position"];
            an.fromValue = [NSValue valueWithCGPoint:CGPointMake(center.x - 40, center.y - 30)];
            an.toValue = [NSValue valueWithCGPoint:CGPointMake(center.x + 40, center.y + 30)];
            an.duration = 6.0 + i;
            an.autoreverses = YES;
            an.repeatCount = HUGE_VALF;
            an.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            [blob addAnimation:an forKey:@"drift"];
        }
    }
    self.meshContainer.hidden = NO;
}

@end

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static AGTBackgroundView *gView;
static UIImage *gArt;
static BOOL gActive;

static void AGTPresent(void) {
    if (!gView) return;
    if (gActive) [gView applyWithArtwork:gArt];
    [UIView animateWithDuration:0.6 animations:^{ gView.alpha = gActive ? 1.0 : 0.0; }];
}

static void AGTSetActive(BOOL on) {
    gActive = on;
    AGTPresent();
}

static void AGTRefresh(void) {
    if (!MRGetAppID || !MRGetPlaying || !MRGetInfo) return;
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
                gArt = data ? [UIImage imageWithData:data] : nil;
                AGTSetActive(YES);
            });
        });
    });
}

static void AGTPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{ AGTPresent(); });
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
    AGTAttach(self.view);
    AGTRefresh();
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
            AGTRefresh();
        }];
    }

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, AGTPrefsChanged,
                                    CFSTR(AGT_PREFS_NOTIF), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    AGTRefresh();
}
