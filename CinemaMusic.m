// ============================================================================
// CinemaMusic.m  —  "Cinema" visual tweak for YouTube Music (built vs 9.22.2)
// arm64 / iOS 18+, plain ObjC runtime swizzling (NO Substrate / Theos needed)
//
// Features: live audio visualizer (4 styles), album-color atmosphere,
// circular spectrum around artwork, glass settings chip, accent tint.
// Audio data: MTAudioProcessingTap on AVPlayerItem (public API, pass-through).
// If the tap yields no data, an animated SIMULATED mode is used (labelled SIM).
//
// UNTESTED ON DEVICE. Class names come from strings in the 9.22.2 binary.
// Everything is wrapped defensively: if something isn't found, it does nothing.
// ============================================================================
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <MediaToolbox/MediaToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <Accelerate/Accelerate.h>
#import <objc/runtime.h>
#import <math.h>

#define CM_BANDS 48
#define FFT_N 1024
#define FFT_LOG2 10

@class CMSession;

#pragma mark - Settings (NSUserDefaults, prefix cm_)

static NSInteger CMInt(NSString *k, NSInteger def) {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:[@"cm_" stringByAppendingString:k]];
    return v ? [v integerValue] : def;
}
static void CMSet(NSString *k, NSInteger v) {
    [NSUserDefaults.standardUserDefaults setInteger:v forKey:[@"cm_" stringByAppendingString:k]];
}
static const float kIntensity[4] = {0.6f, 0.85f, 1.1f, 1.45f};
static const CGFloat kVisH[3] = {56, 80, 110};

static UIColor *CMFixedAccent(NSInteger i) {
    switch (i) {
        case 1: return [UIColor colorWithRed:0.00 green:0.90 blue:1.00 alpha:1]; // cyan
        case 2: return [UIColor colorWithRed:1.00 green:0.15 blue:0.75 alpha:1]; // magenta
        case 3: return [UIColor colorWithRed:0.55 green:1.00 blue:0.20 alpha:1]; // lime
        case 4: return [UIColor colorWithRed:0.62 green:0.35 blue:1.00 alpha:1]; // violet
        case 5: return [UIColor colorWithRed:1.00 green:0.55 blue:0.10 alpha:1]; // orange
        default: return nil;
    }
}
static UIColor *CMShiftHue(UIColor *c, CGFloat d) {
    CGFloat h, s, v, a;
    [c getHue:&h saturation:&s brightness:&v alpha:&a];
    h += d; if (h > 1) h -= 1; if (h < 0) h += 1;
    return [UIColor colorWithHue:h saturation:s brightness:v alpha:1];
}
static UIColor *CMLerp(UIColor *a, UIColor *b, CGFloat t) {
    CGFloat r1, g1, b1, a1, r2, g2, b2, a2;
    [a getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [b getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    return [UIColor colorWithRed:r1 + (r2 - r1) * t green:g1 + (g2 - g1) * t blue:b1 + (b2 - b1) * t alpha:1];
}

#pragma mark - Color extraction (pure CoreGraphics, no 3rd party)

static UIColor *CMNeon(float r, float g, float b) {
    CGFloat h, s, v, a;
    [[UIColor colorWithRed:r green:g blue:b alpha:1] getHue:&h saturation:&s brightness:&v alpha:&a];
    return [UIColor colorWithHue:h saturation:fmax(s, 0.6) brightness:fmax(v, 0.9) alpha:1];
}
static UIColor *CMDark(UIColor *c) {
    CGFloat h, s, v, a;
    [c getHue:&h saturation:&s brightness:&v alpha:&a];
    return [UIColor colorWithHue:h saturation:s brightness:v * 0.30 alpha:1];
}
// returns @[primaryNeon, secondaryNeon, secondaryDark] or nil
static NSArray<UIColor *> *CMExtractColors(UIImage *img) {
    CGImageRef cg = img.CGImage;
    if (!cg) return nil;
    const int W = 32;
    uint8_t px[W * W * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, W, W, 8, W * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, W), cg);
    CGContextRelease(ctx);

    double ws[12] = {0}, rr[12] = {0}, gg[12] = {0}, bb[12] = {0};
    double lum = 0;
    for (int i = 0; i < W * W; i++) {
        float R = px[i * 4] / 255.f, G = px[i * 4 + 1] / 255.f, B = px[i * 4 + 2] / 255.f;
        lum += 0.2126 * R + 0.7152 * G + 0.0722 * B;
        float mx = fmaxf(R, fmaxf(G, B)), mn = fminf(R, fminf(G, B)), d = mx - mn;
        float s = mx > 0 ? d / mx : 0;
        if (mx < 0.18f || s < 0.15f) continue;
        float h;
        if (mx == R) h = fmodf((G - B) / d, 6.f);
        else if (mx == G) h = (B - R) / d + 2.f;
        else h = (R - G) / d + 4.f;
        h *= 60.f; if (h < 0) h += 360.f;
        int bin = ((int)(h / 30.f)) % 12;
        double w = (double)s * s * mx;
        ws[bin] += w; rr[bin] += R * w; gg[bin] += G * w; bb[bin] += B * w;
    }
    lum /= (W * W);
    int p = -1; double best = 0;
    for (int i = 0; i < 12; i++) if (ws[i] > best) { best = ws[i]; p = i; }
    if (p < 0 || best < 0.5) { // basically grayscale artwork
        UIColor *g1 = [UIColor colorWithWhite:fmin(0.95, 0.5 + lum) alpha:1];
        return @[g1, [UIColor colorWithWhite:0.65 alpha:1], [UIColor colorWithWhite:0.10 alpha:1]];
    }
    int s2 = -1; double best2 = 0;
    for (int i = 0; i < 12; i++) {
        int dist = abs(i - p); dist = MIN(dist, 12 - dist);
        if (dist >= 2 && ws[i] > best2 && ws[i] >= best * 0.15) { best2 = ws[i]; s2 = i; }
    }
    UIColor *P = CMNeon(rr[p] / ws[p], gg[p] / ws[p], bb[p] / ws[p]);
    UIColor *S = (s2 >= 0) ? CMNeon(rr[s2] / ws[s2], gg[s2] / ws[s2], bb[s2] / ws[s2]) : CMShiftHue(P, 0.12);
    return @[P, S, CMDark(S)];
}

#pragma mark - Audio analysis (MTAudioProcessingTap + vDSP FFT)

static volatile float gRaw[CM_BANDS];          // written on audio thread
static volatile double gLastTap = 0;           // CACurrentMediaTime of last FFT
static float gSmooth[CM_BANDS];                // main thread, smoothed
static __weak AVPlayer *gPlayer;

typedef struct {
    FFTSetup setup;
    float window[FFT_N];
    float ring[FFT_N];
    int fill;
    float re[FFT_N / 2], im[FFT_N / 2];
    AudioStreamBasicDescription asbd;
} CMTapCtx;

static void CMRunFFT(CMTapCtx *c) {
    float buf[FFT_N];
    vDSP_vmul(c->ring, 1, c->window, 1, buf, 1, FFT_N);
    DSPSplitComplex sp = {c->re, c->im};
    vDSP_ctoz((const DSPComplex *)buf, 2, &sp, 1, FFT_N / 2);
    vDSP_fft_zrip(c->setup, &sp, 1, FFT_LOG2, kFFTDirection_Forward);
    float mags[FFT_N / 2];
    vDSP_zvmags(&sp, 1, mags, 1, FFT_N / 2);

    double sr = c->asbd.mSampleRate > 8000 ? c->asbd.mSampleRate : 44100.0;
    float binHz = (float)(sr / FFT_N);
    float f0 = 45.f, f1 = fminf(16000.f, (float)(sr * 0.5 * 0.95));
    for (int b = 0; b < CM_BANDS; b++) {
        float lo = f0 * powf(f1 / f0, (float)b / CM_BANDS);
        float hi = f0 * powf(f1 / f0, (float)(b + 1) / CM_BANDS);
        int i0 = MAX(1, (int)floorf(lo / binHz));
        int i1 = MIN(FFT_N / 2 - 1, MAX(i0, (int)ceilf(hi / binHz)));
        float pk = 0;
        for (int i = i0; i <= i1; i++) pk = fmaxf(pk, mags[i]);
        float amp = sqrtf(pk) / FFT_N;
        float db = 20.f * log10f(amp + 1e-7f);
        float v = (db + 78.f) / 60.f;                 // -78dB..-18dB -> 0..1
        v += 0.14f * ((float)b / CM_BANDS);           // gentle high-freq tilt
        gRaw[b] = fminf(1.f, fmaxf(0.f, v));
    }
    gLastTap = CACurrentMediaTime();
}

static inline float CMSample(const void *p, size_t idx, BOOL isFloat) {
    return isFloat ? ((const float *)p)[idx] : ((const SInt16 *)p)[idx] / 32768.f;
}
static void CMPush(CMTapCtx *c, AudioBufferList *abl, UInt32 n) {
    AudioStreamBasicDescription f = c->asbd;
    BOOL isFloat = (f.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL nonInt = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    if (isFloat ? f.mBitsPerChannel != 32 : f.mBitsPerChannel != 16) return;
    UInt32 ch = f.mChannelsPerFrame ? f.mChannelsPerFrame : 1;
    for (UInt32 i = 0; i < n; i++) {
        float s = 0;
        if (nonInt) {
            UInt32 nb = abl->mNumberBuffers ? abl->mNumberBuffers : 1;
            for (UInt32 b = 0; b < nb; b++) if (abl->mBuffers[b].mData) s += CMSample(abl->mBuffers[b].mData, i, isFloat);
            s /= nb;
        } else {
            const void *d = abl->mBuffers[0].mData;
            if (!d) return;
            for (UInt32 k = 0; k < ch; k++) s += CMSample(d, (size_t)i * ch + k, isFloat);
            s /= ch;
        }
        c->ring[c->fill++] = s;
        if (c->fill >= FFT_N) {
            CMRunFFT(c);
            memmove(c->ring, c->ring + FFT_N / 2, sizeof(float) * (FFT_N / 2)); // 50% hop
            c->fill = FFT_N / 2;
        }
    }
}

static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **storageOut) { *storageOut = clientInfo; }
static void tapFinalize(MTAudioProcessingTapRef tap) {
    CMTapCtx *c = (CMTapCtx *)MTAudioProcessingTapGetStorage(tap);
    if (c) { if (c->setup) vDSP_destroy_fftsetup(c->setup); free(c); }
}
static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *fmt) {
    CMTapCtx *c = (CMTapCtx *)MTAudioProcessingTapGetStorage(tap);
    if (c && fmt) { c->asbd = *fmt; c->fill = 0; }
}
static void tapUnprepare(MTAudioProcessingTapRef tap) {}
static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount frames, MTAudioProcessingTapFlags flags,
                       AudioBufferList *abl, CMItemCount *framesOut, MTAudioProcessingTapFlags *flagsOut) {
    OSStatus st = MTAudioProcessingTapGetSourceAudio(tap, frames, abl, flagsOut, NULL, framesOut);
    if (st != noErr) return;                       // audio passes through untouched either way
    CMTapCtx *c = (CMTapCtx *)MTAudioProcessingTapGetStorage(tap);
    if (c && c->asbd.mSampleRate > 0) CMPush(c, abl, (UInt32)*framesOut);
}

static const void *kCMTapKey = &kCMTapKey;

static void CMAttachTap(AVPlayerItem *item) {
    if (!item || !CMInt(@"tap", 1) || CMInt(@"tap_off", 0)) return;
    if (objc_getAssociatedObject(item, kCMTapKey)) return;
    objc_setAssociatedObject(item, kCMTapKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak AVPlayerItem *wi = item;
    [item.asset loadTracksWithMediaType:AVMediaTypeAudio completionHandler:^(NSArray<AVAssetTrack *> *tracks, NSError *err) {
        AVPlayerItem *it = wi;
        if (!it || tracks.count == 0) return;      // e.g. streamed asset w/o tracks -> SIM fallback
        dispatch_async(dispatch_get_main_queue(), ^{
            AVPlayerItem *it2 = wi;
            if (!it2 || it2.audioMix) return;      // never override an existing audioMix (EQ etc.)
            CMTapCtx *ctx = calloc(1, sizeof(CMTapCtx));
            if (!ctx) return;
            ctx->setup = vDSP_create_fftsetup(FFT_LOG2, kFFTRadix2);
            vDSP_hann_window(ctx->window, FFT_N, vDSP_HANN_DENORM);
            MTAudioProcessingTapCallbacks cb;
            memset(&cb, 0, sizeof(cb));
            cb.version = kMTAudioProcessingTapCallbacksVersion_0;
            cb.clientInfo = ctx;
            cb.init = tapInit; cb.finalize = tapFinalize; cb.prepare = tapPrepare;
            cb.unprepare = tapUnprepare; cb.process = tapProcess;
            MTAudioProcessingTapRef tap = NULL;
            OSStatus st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
            if (st != noErr || !tap) { if (ctx->setup) vDSP_destroy_fftsetup(ctx->setup); free(ctx); return; }
            AVMutableAudioMixInputParameters *p = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:tracks.firstObject];
            p.audioTapProcessor = tap;
            CFRelease(tap);
            AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
            mix.inputParameters = @[p];
            // crash guard: if we die within 20s of attaching, count it
            [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"cm_tap_pending"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"cm_tap_pending"];
                CMSet(@"crashes", 0);
            });
            it2.audioMix = mix;
        });
    }];
}

#pragma mark - Engine (one display link, smoothing, sim fallback)

@protocol CMFrame <NSObject>
- (void)cmFrame;
@end

@interface CMEngine : NSObject
@property (nonatomic, readonly) BOOL live;
@property (nonatomic, readonly) BOOL playing;
+ (instancetype)shared;
- (void)add:(id<CMFrame>)c;
- (void)remove:(id<CMFrame>)c;
- (void)applyFPS;
@end

@implementation CMEngine {
    CADisplayLink *_link; NSHashTable *_cons; double _t; CFTimeInterval _last;
    BOOL _bg; int _poll; float _npRate;
}
+ (instancetype)shared {
    static CMEngine *e; static dispatch_once_t o;
    dispatch_once(&o, ^{ e = [CMEngine new]; });
    return e;
}
- (instancetype)init {
    if ((self = [super init])) {
        _cons = [NSHashTable weakObjectsHashTable];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(goBg) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(goFg) name:UIApplicationWillEnterForegroundNotification object:nil];
    }
    return self;
}
- (void)goBg { _bg = YES; [self sync]; }
- (void)goFg { _bg = NO; [self sync]; }
- (void)sync { _link.paused = (_cons.count == 0 || _bg); }
- (void)applyFPS { _link.preferredFramesPerSecond = CMInt(@"fps", 0) ? 60 : 30; }
- (void)add:(id<CMFrame>)c {
    [_cons addObject:c];
    if (!_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        _last = CACurrentMediaTime();
    }
    [self applyFPS]; [self sync];
}
- (void)remove:(id<CMFrame>)c { [_cons removeObject:c]; [self sync]; }

- (BOOL)computePlaying {
    AVPlayer *p = gPlayer;
    if (p && p.rate > 0.01f) return YES;
    if ((_poll++ % 20) == 0) {
        NSDictionary *i = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
        _npRate = [i[MPNowPlayingInfoPropertyPlaybackRate] floatValue];
    }
    return _npRate > 0.01f;
}

- (void)tick:(CADisplayLink *)l {
    CFTimeInterval now = CACurrentMediaTime();
    double dt = fmin(0.1, fmax(0.001, now - _last)); _last = now; _t += dt;
    BOOL playing = [self computePlaying];
    BOOL live = (now - gLastTap) < 0.35;
    float target[CM_BANDS];
    if (!playing) {
        memset(target, 0, sizeof(target));
    } else if (live) {
        for (int i = 0; i < CM_BANDS; i++) target[i] = gRaw[i];
    } else if (CMInt(@"sim", 1)) {
        for (int i = 0; i < CM_BANDS; i++) {
            float x = (float)i / (CM_BANDS - 1);
            float env = 0.55f * (1.f - 0.55f * x);
            float w1 = 0.5f + 0.5f * sinf((float)_t * (1.7f + x * 3.1f) + i * 0.9f);
            float w2 = 0.5f + 0.5f * sinf((float)_t * (0.8f + x * 1.9f) + i * 1.7f + 1.3f);
            float pulse = powf(fmaxf(0.f, sinf((float)_t * 2.f * (float)M_PI * 1.9f)), 5.f) * (1.f - x) * 0.5f;
            target[i] = fminf(1.f, env * (0.35f + 0.65f * w1 * w2) + pulse) * 0.9f;
        }
    } else {
        memset(target, 0, sizeof(target));
    }
    _live = playing && live; _playing = playing;
    float k = kIntensity[CMInt(@"intensity", 1) % 4];
    for (int i = 0; i < CM_BANDS; i++) {
        float t = fminf(1.f, target[i] * k);
        float base = t > gSmooth[i] ? 0.55f : 0.10f;
        float a = 1.f - powf(1.f - base, (float)dt * 60.f);
        gSmooth[i] += (t - gSmooth[i]) * a;
    }
    for (id<CMFrame> c in _cons.allObjects) [c cmFrame];
}
@end

#pragma mark - Views

@interface CMAtmo : UIView
- (void)applyOverlay:(BOOL)ov;
- (void)setPrimary:(UIColor *)p dark:(UIColor *)d art:(UIImage *)img glowCenter:(CGPoint)gc;
@end
@implementation CMAtmo {
    CAGradientLayer *_g, *_glow; UIImageView *_art; UIVisualEffectView *_blur; NSString *_key;
}
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.blackColor;
        _art = [UIImageView new]; _art.contentMode = UIViewContentModeScaleAspectFill; _art.clipsToBounds = YES; _art.alpha = 0.65;
        [self addSubview:_art];
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        [self addSubview:_blur];
        _g = [CAGradientLayer layer]; _g.locations = @[@0, @0.55, @1];
        _g.startPoint = CGPointMake(0.5, 0); _g.endPoint = CGPointMake(0.5, 1);
        [self.layer addSublayer:_g];
        _glow = [CAGradientLayer layer]; _glow.type = kCAGradientLayerRadial;
        [self.layer addSublayer:_glow];
    }
    return self;
}
- (void)applyOverlay:(BOOL)ov {
    self.backgroundColor = ov ? UIColor.clearColor : UIColor.blackColor;
    self.alpha = ov ? 0.30 : 1.0;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _g.frame = self.bounds; _glow.frame = self.bounds;
    _art.frame = self.bounds; _blur.frame = self.bounds;
    [CATransaction commit];
}
- (void)setPrimary:(UIColor *)p dark:(UIColor *)d art:(UIImage *)img glowCenter:(CGPoint)gc {
    BOOL glow = CMInt(@"glow", 1), blur = CMInt(@"blur", 0);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _glow.startPoint = gc; _glow.endPoint = CGPointMake(gc.x + 0.85, gc.y + 0.60);
    [CATransaction commit];
    NSString *key = [NSString stringWithFormat:@"%@|%@|%d|%d|%p", p, d, glow, blur, img.CGImage];
    if ([key isEqualToString:_key]) return;
    _key = key;
    CGFloat k = blur ? 0.55 : 1.0;
    [CATransaction begin]; [CATransaction setAnimationDuration:1.0];
    _g.colors = @[(id)[p colorWithAlphaComponent:0.55 * k].CGColor,
                  (id)[d colorWithAlphaComponent:0.60 * k].CGColor,
                  (id)UIColor.blackColor.CGColor];
    _glow.colors = @[(id)[p colorWithAlphaComponent:glow ? 0.50 : 0].CGColor,
                     (id)[p colorWithAlphaComponent:0].CGColor];
    [CATransaction commit];
    _art.hidden = _blur.hidden = !blur;
    if (blur && img && _art.image.CGImage != img.CGImage) {
        [UIView transitionWithView:_art duration:0.8 options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ self->_art.image = img; } completion:nil];
    }
}
@end

// ---- bars / mirror / wave / dots ----
@interface CMVisView : UIView <CMFrame>
- (void)setAccent:(UIColor *)a accent2:(UIColor *)b;
@end
@implementation CMVisView { NSArray<UIColor *> *_cols; UIColor *_a; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.opaque = NO; self.backgroundColor = UIColor.clearColor; self.userInteractionEnabled = NO;
        self.layer.shadowOffset = CGSizeZero; self.layer.shadowRadius = 10;
    }
    return self;
}
- (void)setAccent:(UIColor *)a accent2:(UIColor *)b {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:CM_BANDS];
    for (int i = 0; i < CM_BANDS; i++) [arr addObject:CMLerp(a, b, (CGFloat)i / (CM_BANDS - 1))];
    _cols = arr; _a = a;
    self.layer.shadowColor = a.CGColor;
    self.layer.shadowOpacity = CMInt(@"glow", 1) ? 0.85 : 0;
}
- (void)cmFrame { if (!self.hidden && self.window) [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    if (!_cols) return;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat gap = 3, bw = (W - gap * (CM_BANDS - 1)) / CM_BANDS;
    switch (CMInt(@"style", 0) % 4) {
        case 0: // bars
            for (int i = 0; i < CM_BANDS; i++) {
                CGFloat h = fmax(3, gSmooth[i] * H);
                [_cols[i] setFill];
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(i * (bw + gap), H - h, bw, h) cornerRadius:bw / 2] fill];
            }
            break;
        case 1: // mirror
            for (int i = 0; i < CM_BANDS; i++) {
                CGFloat h = fmax(3, gSmooth[i] * H);
                [_cols[i] setFill];
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(i * (bw + gap), (H - h) / 2, bw, h) cornerRadius:bw / 2] fill];
            }
            break;
        case 2: { // wave
            CGFloat step = W / (CM_BANDS - 1);
            UIBezierPath *line = [UIBezierPath bezierPath];
            CGPoint prev = CGPointMake(0, H - fmax(2, gSmooth[0] * H));
            [line moveToPoint:prev];
            for (int i = 1; i < CM_BANDS; i++) {
                CGPoint pt = CGPointMake(i * step, H - fmax(2, gSmooth[i] * H));
                CGPoint mid = CGPointMake((prev.x + pt.x) / 2, (prev.y + pt.y) / 2);
                [line addQuadCurveToPoint:mid controlPoint:prev];
                prev = pt;
            }
            [line addLineToPoint:prev];
            UIBezierPath *fill = [line copy];
            [fill addLineToPoint:CGPointMake(W, H)]; [fill addLineToPoint:CGPointMake(0, H)]; [fill closePath];
            [[_a colorWithAlphaComponent:0.30] setFill]; [fill fill];
            [_a setStroke]; line.lineWidth = 2.5; line.lineCapStyle = kCGLineCapRound; [line stroke];
            break;
        }
        default: { // dots
            CGFloat r = bw / 2, pitch = bw + 3;
            for (int i = 0; i < CM_BANDS; i++) {
                int rows = (int)(gSmooth[i] * (H / pitch)) + 1;
                [_cols[i] setFill];
                for (int k = 0; k < rows; k++) {
                    CGContextFillEllipseInRect(c, CGRectMake(i * (bw + gap), H - (k + 1) * pitch, r * 2, r * 2));
                }
            }
        }
    }
}
@end

// ---- circular spectrum around the artwork ----
@interface CMRingView : UIView <CMFrame>
@property (nonatomic) CGRect artRect;
- (void)setAccent:(UIColor *)a accent2:(UIColor *)b;
@end
@implementation CMRingView { NSArray<UIColor *> *_cols; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.opaque = NO; self.backgroundColor = UIColor.clearColor; self.userInteractionEnabled = NO;
        self.layer.shadowOffset = CGSizeZero; self.layer.shadowRadius = 8;
    }
    return self;
}
- (void)setAccent:(UIColor *)a accent2:(UIColor *)b {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:CM_BANDS];
    for (int i = 0; i < CM_BANDS; i++) [arr addObject:CMLerp(a, b, (CGFloat)i / (CM_BANDS - 1))];
    _cols = arr;
    self.layer.shadowColor = a.CGColor;
    self.layer.shadowOpacity = CMInt(@"glow", 1) ? 0.8 : 0;
}
- (void)cmFrame { if (!self.hidden && self.window) [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    if (!_cols || CGRectIsEmpty(_artRect)) return;
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGPoint ctr = CGPointMake(CGRectGetMidX(_artRect), CGRectGetMidY(_artRect));
    CGFloat r0 = MIN(_artRect.size.width, _artRect.size.height) / 2 * 1.08;
    CGFloat maxLen = r0 * 0.30;
    CGContextSaveGState(c);
    // draw only OUTSIDE the artwork rect, so bars look like they sit behind it
    CGContextAddRect(c, self.bounds); CGContextAddRect(c, _artRect); CGContextEOClip(c);
    CGContextSetLineCap(c, kCGLineCapRound); CGContextSetLineWidth(c, 3);
    const int N = CM_BANDS * 2;
    for (int k = 0; k < N; k++) {
        int idx = k < CM_BANDS ? k : (N - 1 - k);   // left/right symmetric
        CGFloat ang = -M_PI_2 + 2 * M_PI * k / N;
        CGFloat len = 4 + gSmooth[idx] * maxLen;
        CGContextSetStrokeColorWithColor(c, _cols[idx].CGColor);
        CGContextMoveToPoint(c, ctr.x + cos(ang) * r0, ctr.y + sin(ang) * r0);
        CGContextAddLineToPoint(c, ctr.x + cos(ang) * (r0 + len), ctr.y + sin(ang) * (r0 + len));
        CGContextStrokePath(c);
    }
    CGContextRestoreGState(c);
}
@end

@interface CMHostView : UIView
@property (nonatomic, weak) CMSession *session;
@property (nonatomic, strong) CMVisView *vis;
@property (nonatomic, strong) CMRingView *ring;
@property (nonatomic, strong) UIVisualEffectView *chip;
@property (nonatomic, strong) UILabel *chipLabel;
- (void)layoutForArtwork:(UIView *)art;
- (void)applyAccent:(UIColor *)a accent2:(UIColor *)b;
- (void)updateStatus;
@end

@interface CMSession : NSObject
@property (nonatomic, weak) UIViewController *vc;
@property (nonatomic) BOOL active;
- (void)start; - (void)stop; - (void)layout; - (void)showMenu; - (void)quickCycle;
@end

#pragma mark - Artwork finder (heuristic: big, square, centered, has an image)

static UIImage *CMImageIn(UIView *v, int depth) {
    if ([v isKindOfClass:UIImageView.class]) { UIImage *i = ((UIImageView *)v).image; if (i) return i; }
    if (depth <= 0) return nil;
    for (UIView *s in v.subviews) { UIImage *i = CMImageIn(s, depth - 1); if (i) return i; }
    return nil;
}
static UIView *CMFindArtwork(UIView *root) {
    CGFloat W = root.bounds.size.width;
    UIView *best = nil; CGFloat bestArea = 0; int guard = 0;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    while (q.count && guard++ < 500) {
        UIView *v = q.firstObject; [q removeObjectAtIndex:0];
        for (UIView *s in v.subviews) {
            if (s.hidden || s.alpha < 0.05 || [s isKindOfClass:CMHostView.class] || [s isKindOfClass:CMAtmo.class]) continue;
            CGSize z = s.bounds.size;
            if (z.height > 1 && z.width > W * 0.45 && z.width <= W * 1.02 && fabs(z.width / z.height - 1) < 0.04) {
                CGRect f = [s convertRect:s.bounds toView:root];
                CGFloat mx = CGRectGetMidX(f);
                if (mx > W * 0.25 && mx < W * 0.75 && CGRectIntersectsRect(f, root.bounds) && CMImageIn(s, 3)) {
                    CGFloat area = z.width * z.height;
                    if (area > bestArea) { bestArea = area; best = s; }
                }
            }
            [q addObject:s];
        }
    }
    return best;
}

#pragma mark - Host overlay (pass-through, owns visualizer, ring, glass chip)

@implementation CMHostView
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.clearColor;
        _ring = [CMRingView new]; [self addSubview:_ring];
        _vis = [CMVisView new]; _vis.alpha = 0.9; [self addSubview:_vis];

        _chip = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _chip.frame = CGRectMake(0, 0, 86, 28);
        _chip.layer.cornerRadius = 14; _chip.clipsToBounds = YES;
        _chip.layer.borderWidth = 0.6; _chip.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        _chipLabel = [[UILabel alloc] initWithFrame:_chip.bounds];
        _chipLabel.textAlignment = NSTextAlignmentCenter;
        _chipLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _chipLabel.textColor = UIColor.whiteColor;
        [_chip.contentView addSubview:_chipLabel];
        [self addSubview:_chip];
        [_chip addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tap)]];
        [_chip addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hold:)]];
        [_chip addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    }
    return self;
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *h = [super hitTest:p withEvent:e];
    return (h == self || h == _ring || h == _vis) ? nil : h;   // pass everything through except the chip
}
- (void)tap { [self.session showMenu]; }
- (void)hold:(UILongPressGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateBegan) [self.session quickCycle]; }
- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    _chip.center = CGPointMake(_chip.center.x + t.x, _chip.center.y + t.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded && self.bounds.size.width > 0) {
        [NSUserDefaults.standardUserDefaults setDouble:_chip.center.x / self.bounds.size.width forKey:@"cm_cx"];
        [NSUserDefaults.standardUserDefaults setDouble:_chip.center.y / self.bounds.size.height forKey:@"cm_cy"];
    }
}
- (void)layoutForArtwork:(UIView *)art {
    CGRect b = self.bounds;
    UIEdgeInsets sa = self.superview.safeAreaInsets;
    CGFloat vh = kVisH[CMInt(@"vh", 1) % 3];
    _vis.frame = CGRectMake(12, b.size.height - sa.bottom - vh - 6, b.size.width - 24, vh);
    _vis.hidden = !CMInt(@"vis", 1);
    _ring.frame = b;
    if (art && CMInt(@"ring", 1)) { _ring.artRect = [art convertRect:art.bounds toView:self]; _ring.hidden = NO; }
    else _ring.hidden = YES;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:@"cm_cx"] && b.size.width > 0) {
        _chip.center = CGPointMake([d doubleForKey:@"cm_cx"] * b.size.width, [d doubleForKey:@"cm_cy"] * b.size.height);
    } else {
        _chip.center = CGPointMake(b.size.width - 16 - 43, _vis.frame.origin.y - 18);
    }
}
- (void)applyAccent:(UIColor *)a accent2:(UIColor *)b {
    [_vis setAccent:a accent2:b]; [_ring setAccent:a accent2:b];
}
- (void)updateStatus {
    CMEngine *e = CMEngine.shared;
    if (CMInt(@"tap_off", 0)) { _chipLabel.text = @"● SAFE"; _chipLabel.textColor = [UIColor colorWithRed:1 green:0.6 blue:0.2 alpha:1]; }
    else if (!e.playing) { _chipLabel.text = @"○ IDLE"; _chipLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7]; }
    else if (e.live) { _chipLabel.text = @"● LIVE"; _chipLabel.textColor = [UIColor colorWithRed:0.3 green:1 blue:0.5 alpha:1]; }
    else { _chipLabel.text = @"● SIM"; _chipLabel.textColor = [UIColor colorWithRed:1 green:0.8 blue:0.3 alpha:1]; }
}
@end

#pragma mark - Session (one per Now Playing controller)

@implementation CMSession {
    CMAtmo *_atmo; CMHostView *_host; NSTimer *_timer;
    const void *_lastCG; NSArray<UIColor *> *_pal; UIImage *_lastImg; UIView *_art;
}
- (void)start {
    if (_active) return;
    UIView *root = _vc.view; if (!root) return;
    _active = YES;
    if (!_atmo) { _atmo = [CMAtmo new]; _host = [CMHostView new]; _host.session = self; }
    [CMEngine.shared add:_host.vis]; [CMEngine.shared add:_host.ring];
    __weak CMSession *w = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [w refresh]; }];
    [self refresh];
}
- (void)stop {
    if (!_active) return;
    _active = NO;
    [_timer invalidate]; _timer = nil;
    [CMEngine.shared remove:_host.vis]; [CMEngine.shared remove:_host.ring];
    [_host removeFromSuperview]; [_atmo removeFromSuperview];
}
- (void)install {
    UIView *root = _vc.view;
    BOOL ov = CMInt(@"amode", 0) == 1;
    [_atmo applyOverlay:ov];
    if (CMInt(@"atmo", 1)) {
        BOOL placed = (_atmo.superview == root) && (ov || root.subviews.firstObject == _atmo);
        if (!placed) { [_atmo removeFromSuperview]; if (ov) [root addSubview:_atmo]; else [root insertSubview:_atmo atIndex:0]; }
    } else [_atmo removeFromSuperview];
    if (_host.superview != root) [root addSubview:_host];
    else if (root.subviews.lastObject != _host) [root bringSubviewToFront:_host];
}
- (void)layout {
    if (!_active) return;
    UIView *root = _vc.view;
    [self install];
    _atmo.frame = root.bounds; _host.frame = root.bounds;
    [_host layoutForArtwork:_art];
}
- (void)refresh {
    UIView *root = _vc.view;
    BOOL vis = root.window != nil;
    _host.hidden = !vis; _atmo.hidden = !vis;
    if (!vis) return;
    _art = CMFindArtwork(root);
    UIImage *img = _art ? CMImageIn(_art, 3) : nil;
    if (img && img.CGImage != _lastCG) {
        _lastCG = img.CGImage; _lastImg = img;
        __weak CMSession *w = self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSArray *pal = CMExtractColors(img);
            dispatch_async(dispatch_get_main_queue(), ^{
                CMSession *s = w; if (s && s->_lastCG == img.CGImage && pal) { s->_pal = pal; [s refresh]; }
            });
        });
    }
    [self layout];
    UIColor *p = _pal ? _pal[0] : CMFixedAccent(1);
    UIColor *s2 = _pal ? _pal[1] : CMFixedAccent(4);
    UIColor *dk = _pal ? _pal[2] : CMDark(CMFixedAccent(4));
    CGSize sz = root.bounds.size;
    CGPoint gc = _art ? CGPointMake(CGRectGetMidX([_art convertRect:_art.bounds toView:root]) / sz.width,
                                    CGRectGetMidY([_art convertRect:_art.bounds toView:root]) / sz.height)
                      : CGPointMake(0.5, 0.35);
    [_atmo setPrimary:p dark:dk art:_lastImg glowCenter:gc];
    UIColor *fixed = CMFixedAccent(CMInt(@"accent", 0));
    UIColor *a1 = fixed ?: p, *a2 = fixed ? CMShiftHue(fixed, 0.14) : s2;
    [_host applyAccent:a1 accent2:a2];
    root.tintColor = CMInt(@"tint", 1) ? a1 : nil;
    [CMEngine.shared applyFPS];
    [_host updateStatus];
}
- (void)quickCycle { CMSet(@"style", (CMInt(@"style", 0) + 1) % 4); [self refresh]; }

- (void)addCycle:(NSString *)title key:(NSString *)key names:(NSArray<NSString *> *)names def:(NSInteger)def to:(UIAlertController *)a {
    NSInteger cur = CMInt(key, def) % (NSInteger)names.count;
    __weak CMSession *w = self;
    [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@: %@", title, names[cur]]
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        CMSet(key, (cur + 1) % (NSInteger)names.count); [w refresh];
    }]];
}
- (void)showMenu {
    UIViewController *top = _vc;
    while (top.presentedViewController) top = top.presentedViewController;
    CMEngine *e = CMEngine.shared;
    NSString *mode = CMInt(@"tap_off", 0) ? @"crash guard (simulated)" : (e.live ? @"live audio tap" : (e.playing ? @"simulated" : @"idle"));
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Cinema"
                                                               message:[@"Audio: " stringByAppendingString:mode]
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *oo = @[@"Off", @"On"];
    [self addCycle:@"Style" key:@"style" names:@[@"Bars", @"Mirror", @"Wave", @"Dots"] def:0 to:a];
    [self addCycle:@"Accent" key:@"accent" names:@[@"Auto (album)", @"Cyan", @"Magenta", @"Lime", @"Violet", @"Orange"] def:0 to:a];
    [self addCycle:@"Intensity" key:@"intensity" names:@[@"60%", @"85%", @"110%", @"145%"] def:1 to:a];
    [self addCycle:@"Visualizer" key:@"vis" names:oo def:1 to:a];
    [self addCycle:@"Visualizer height" key:@"vh" names:@[@"Small", @"Medium", @"Large"] def:1 to:a];
    [self addCycle:@"Circular ring" key:@"ring" names:oo def:1 to:a];
    [self addCycle:@"Atmosphere" key:@"atmo" names:oo def:1 to:a];
    [self addCycle:@"Atmosphere layer" key:@"amode" names:@[@"Behind", @"Overlay"] def:0 to:a];
    [self addCycle:@"Glow" key:@"glow" names:oo def:1 to:a];
    [self addCycle:@"Blur artwork" key:@"blur" names:oo def:0 to:a];
    [self addCycle:@"Accent tint" key:@"tint" names:oo def:1 to:a];
    [self addCycle:@"Simulated fallback" key:@"sim" names:oo def:1 to:a];
    [self addCycle:@"FPS" key:@"fps" names:@[@"30", @"60"] def:0 to:a];
    if (CMInt(@"tap_off", 0)) {
        __weak CMSession *w = self;
        [a addAction:[UIAlertAction actionWithTitle:@"Retry live audio tap" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            CMSet(@"tap_off", 0); CMSet(@"crashes", 0); [w refresh];
        }]];
    }
    __weak CMSession *w2 = self;
    [a addAction:[UIAlertAction actionWithTitle:@"Reset to defaults" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        for (NSString *k in d.dictionaryRepresentation.allKeys) if ([k hasPrefix:@"cm_"]) [d removeObjectForKey:k];
        [w2 refresh];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = _host.chip;
    a.popoverPresentationController.sourceRect = _host.chip.bounds;
    [top presentViewController:a animated:YES completion:nil];
}
@end

#pragma mark - Hooks (plain ObjC runtime swizzling)

static void CMSwizzle(Class c, SEL s, IMP n, IMP *o) {
    if (!c) return;
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (class_addMethod(c, s, n, method_getTypeEncoding(m))) *o = old;   // method was inherited
    else *o = method_setImplementation(m, n);
}

static const void *kCMSess = &kCMSess;
static CMSession *CMSess(id vc, BOOL create) {
    CMSession *s = objc_getAssociatedObject(vc, kCMSess);
    if (!s && create) {
        s = [CMSession new]; s.vc = vc;
        objc_setAssociatedObject(vc, kCMSess, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return s;
}

// YTMNowPlayingViewController
static void (*o_vda)(id, SEL, BOOL);
static void n_vda(id s, SEL c, BOOL a) { o_vda(s, c, a); @try { [CMSess(s, YES) start]; } @catch (NSException *e) {} }
static void (*o_vwd)(id, SEL, BOOL);
static void n_vwd(id s, SEL c, BOOL a) { o_vwd(s, c, a); @try { [CMSess(s, NO) stop]; } @catch (NSException *e) {} }
static void (*o_vdl)(id, SEL);
static void n_vdl(id s, SEL c) { o_vdl(s, c); @try { [CMSess(s, NO) layout]; } @catch (NSException *e) {} }

// AVPlayer
static void (*o_rep)(id, SEL, AVPlayerItem *);
static void n_rep(id s, SEL c, AVPlayerItem *i) { o_rep(s, c, i); @try { gPlayer = s; CMAttachTap(i); } @catch (NSException *e) {} }
static id (*o_init)(id, SEL, AVPlayerItem *);
static id n_init(id s, SEL c, AVPlayerItem *i) { id r = o_init(s, c, i); @try { gPlayer = r; CMAttachTap(i); } @catch (NSException *e) {} return r; }
static void (*o_play)(id, SEL);
static void n_play(id s, SEL c) { o_play(s, c); @try { gPlayer = s; CMAttachTap([(AVPlayer *)s currentItem]); } @catch (NSException *e) {} }

static BOOL CMInstallVC(void) {
    static BOOL done;
    if (done) return YES;
    Class vc = NSClassFromString(@"YTMNowPlayingViewController");
    if (!vc) return NO;
    done = YES;
    CMSwizzle(vc, @selector(viewDidAppear:), (IMP)n_vda, (IMP *)&o_vda);
    CMSwizzle(vc, @selector(viewWillDisappear:), (IMP)n_vwd, (IMP *)&o_vwd);
    CMSwizzle(vc, @selector(viewDidLayoutSubviews), (IMP)n_vdl, (IMP *)&o_vdl);
    return YES;
}

__attribute__((constructor)) static void CMEntry(void) {
    @autoreleasepool {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        if ([d boolForKey:@"cm_tap_pending"]) {                 // died within 20s of attaching a tap
            NSInteger n = [d integerForKey:@"cm_crashes"] + 1;
            [d setInteger:n forKey:@"cm_crashes"]; [d setBool:NO forKey:@"cm_tap_pending"];
            if (n >= 2) CMSet(@"tap_off", 1);
        }
        Class ap = AVPlayer.class;
        CMSwizzle(ap, @selector(replaceCurrentItemWithPlayerItem:), (IMP)n_rep, (IMP *)&o_rep);
        CMSwizzle(ap, @selector(initWithPlayerItem:), (IMP)n_init, (IMP *)&o_init);
        CMSwizzle(ap, @selector(play), (IMP)n_play, (IMP *)&o_play);
        if (!CMInstallVC()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ CMInstallVC(); });
        }
    }
}
