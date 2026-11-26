#import <QuartzCore/QuartzCore.h>
#import "NBBarView.h"
#import "NBDataSource.h"
#import "NBSettings.h"
#import "NBActions.h"

#pragma mark - Helpers

// All motion is slowed down by the "animation slowdown" setting (default x2).
#define NBD(x) ((x) * [NBSettings shared].animScale)

static NSString *NBFmt(NSTimeInterval s) {
    NSInteger t = MAX(0, (NSInteger)s);
    NSInteger h = t / 3600, m = (t % 3600) / 60, sec = t % 60;
    if (h) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)h, (long)m, (long)sec];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)m, (long)sec];
}

static NSString *NBClock(NSDate *d) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.timeStyle = NSDateFormatterShortStyle;
        f.dateStyle = NSDateFormatterNoStyle;
    });
    return d ? [f stringFromDate:d] : @"--:--";
}

static UIFont *NBMono(CGFloat size, UIFontWeight weight) {
    return [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
}

// Mixes a colour with white by `amount` (0...1).
static UIColor *NBLighten(UIColor *c, CGFloat amount) {
    if (amount <= 0.001) return c;
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if (![c getWhite:&w alpha:&a]) return c;
        r = g = b = w;
    }
    return [UIColor colorWithRed:r + (1 - r) * amount green:g + (1 - g) * amount blue:b + (1 - b) * amount alpha:a];
}

static UIColor *NBBlue(void) { return [UIColor colorWithRed:0.30 green:0.58 blue:1.0 alpha:1]; }
static UIColor *NBBlueSolid(void) { return [UIColor colorWithRed:0.04 green:0.52 blue:1.0 alpha:1]; }

static UIImage *NBSym(NSString *name, CGFloat pt) {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightSemibold];
    return [UIImage systemImageNamed:name withConfiguration:c];
}

static UIButton *NBButton(NSString *sym, CGFloat pt) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:NBSym(sym, pt) forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    return b;
}

static UIColor *NBAccent(void) {
    return [UIColor colorWithRed:1.0 green:0.62 blue:0.04 alpha:1.0];
}

#pragma mark - Progress ring (timer / alarm icon)

@interface NBRingView : UIView
@property (nonatomic) CGFloat progress;
- (void)setGlyph:(NSString *)name;
- (void)setAccent:(UIColor *)accent;   // nil = default orange
- (void)setPlain:(BOOL)plain;          // plain: no ring, only a tinted round icon (status cards)
- (void)setBare:(BOOL)bare;            // bare: only a big coloured glyph (timer / alarm / stopwatch)
@end

@implementation NBRingView {
    BOOL _plain;
    BOOL _bare;
    CAShapeLayer *_track;
    CAShapeLayer *_arc;
    UIImageView *_glyph;
    NSString *_glyphName;
    CGFloat _progress;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _progress = 1;
        _track = [CAShapeLayer layer];
        _track.fillColor = nil;
        _track.strokeColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        _arc = [CAShapeLayer layer];
        _arc.fillColor = nil;
        _arc.strokeColor = NBAccent().CGColor;
        _arc.lineCap = kCALineCapRound;
        [self.layer addSublayer:_track];
        [self.layer addSublayer:_arc];
        _glyph = [UIImageView new];
        _glyph.contentMode = UIViewContentModeCenter;
        _glyph.tintColor = NBAccent();
        [self addSubview:_glyph];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat lw = MAX(2.5, w * 0.085);
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:c
                                                     radius:(w - lw) / 2
                                                 startAngle:-M_PI_2
                                                   endAngle:M_PI * 1.5
                                                  clockwise:YES];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _track.frame = self.bounds;
    _arc.frame = self.bounds;
    _track.path = p.CGPath;
    _arc.path = p.CGPath;
    _track.lineWidth = lw;
    _arc.lineWidth = lw;
    _arc.strokeEnd = _progress;
    [CATransaction commit];
    _track.hidden = _plain || _bare;
    _arc.hidden = _plain || _bare;
    _glyph.frame = self.bounds;
    _glyph.layer.cornerRadius = _plain ? w / 2 : 0;
    _glyph.backgroundColor = _plain ? [_glyph.tintColor colorWithAlphaComponent:0.2] : [UIColor clearColor];
    if (_glyphName) _glyph.image = NBSym(_glyphName, w * (_bare ? 0.7 : (_plain ? 0.46 : 0.42)));
}

- (void)setAccent:(UIColor *)accent {
    UIColor *c = accent ?: NBAccent();
    _arc.strokeColor = c.CGColor;
    _glyph.tintColor = c;
    [self setNeedsLayout];
}

- (void)setBare:(BOOL)bare {
    _bare = bare;
    [self setNeedsLayout];
}

- (void)setPlain:(BOOL)plain {
    _plain = plain;
    [self setNeedsLayout];
}

- (void)setGlyph:(NSString *)name {
    _glyphName = [name copy];
    [self setNeedsLayout];
}

- (void)setProgress:(CGFloat)progress {
    _progress = MAX(0, MIN(1, progress));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _arc.strokeEnd = _progress;
    [CATransaction commit];
}

- (CGFloat)progress { return _progress; }

@end

#pragma mark - Equalizer

@interface NBEQView : UIView
- (void)setPlaying:(BOOL)playing;
@end

@implementation NBEQView {
    NSArray<CALayer *> *_bars;
    BOOL _playing;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        NSMutableArray *bars = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            CALayer *l = [CALayer layer];
            l.backgroundColor = [UIColor whiteColor].CGColor;
            l.cornerRadius = 1.5;
            l.anchorPoint = CGPointMake(0.5, 1);
            [self.layer addSublayer:l];
            [bars addObject:l];
        }
        _bars = bars;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    CGFloat x0 = (self.bounds.size.width - 14) / 2;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int i = 0; i < 3; i++) {
        CALayer *l = _bars[i];
        l.bounds = CGRectMake(0, 0, 3, h);
        l.position = CGPointMake(x0 + 1.5 + i * 5.5, h);
    }
    [CATransaction commit];
    [self applyAnimation];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self applyAnimation];
}

- (void)setPlaying:(BOOL)playing {
    _playing = playing;
    [self applyAnimation];
}

- (void)applyAnimation {
    static const double durations[3] = {0.45, 0.62, 0.52};
    for (int i = 0; i < 3; i++) {
        CALayer *l = _bars[i];
        if (_playing && self.window) {
            if (![l animationForKey:@"eq"]) {
                CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
                a.fromValue = @0.25;
                a.toValue = @1.0;
                a.duration = durations[i];
                a.autoreverses = YES;
                a.repeatCount = HUGE_VALF;
                a.timeOffset = i * 0.15;
                [l addAnimation:a forKey:@"eq"];
            }
        } else {
            [l removeAnimationForKey:@"eq"];
            l.transform = CATransform3DMakeScale(1, 0.3, 1);
        }
    }
}

@end

#pragma mark - Card

@interface NBCardView : UIView
@property (nonatomic, readonly) NBItem *item;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic, copy) void (^onPrev)(void);
@property (nonatomic, copy) void (^onPlay)(void);
@property (nonatomic, copy) void (^onNext)(void);
@property (nonatomic, copy) void (^onTimerToggle)(void);
@property (nonatomic, copy) void (^onTimerStop)(void);
+ (CGFloat)expandedHeightForItem:(NBItem *)item;
- (void)setCollapsedSize:(CGSize)cs expandedSize:(CGSize)es;
- (void)configure:(NBItem *)item;
- (void)applyStyle;
- (void)layoutBoxesExpanded:(BOOL)expanded;
- (void)setBoxAlphasExpanded:(BOOL)expanded backdrop:(BOOL)backdrop;
- (void)tick;
@end

@implementation NBCardView {
    NBItem *_item;
    UIView *_host;
    UIVisualEffectView *_blur;
    UIView *_collapsedBox;
    UIView *_expandedBox;
    CGSize _cs, _es;
    CGFloat _cornerRadius;
    BOOL _blurOn;
    BOOL _styleInit;

    // collapsed content
    UIImageView *_cArt;
    NBRingView *_cRing;
    UILabel *_cTitle, *_cSub;
    UIButton *_cPlay, *_cPrev, *_cNext;

    // expanded content
    UIImageView *_eArt;
    UILabel *_eTitle, *_eSub, *_eBig, *_eTimeL, *_eTimeR;
    NBEQView *_eEq;
    UIView *_eTrack, *_eFill;
    UIButton *_ePrev, *_ePlay, *_eNext, *_eToggle, *_eStop;
}

+ (CGFloat)expandedHeightForItem:(NBItem *)item {
    switch (item.type) {
        case NBItemTypeMedia: return 150;
        case NBItemTypeTimer: return 140;
        case NBItemTypeStopwatch: return 104;
        default: return 92;
    }
}

- (NBItem *)item { return _item; }

- (UILabel *)labelAlpha:(CGFloat)alpha {
    UILabel *l = [UILabel new];
    l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = NO;
        _host = [[UIView alloc] initWithFrame:self.bounds];
        _host.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_host];

        _blur = [[UIVisualEffectView alloc] initWithEffect:nil];
        _blur.frame = _host.bounds;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blur.clipsToBounds = YES;
        _blur.layer.cornerCurve = kCACornerCurveContinuous;
        _blur.layer.borderWidth = 1.0;                       // ColorOS: thin light rim around the glass
        _blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.24].CGColor;
        [_host addSubview:_blur];

        _collapsedBox = [UIView new];
        _expandedBox = [UIView new];
        _expandedBox.alpha = 0;
        [_blur.contentView addSubview:_collapsedBox];
        [_blur.contentView addSubview:_expandedBox];

        // collapsed
        _cArt = [UIImageView new];
        _cArt.clipsToBounds = YES;
        _cArt.tintColor = [UIColor whiteColor];
        _cRing = [NBRingView new];
        _cTitle = [self labelAlpha:1];
        _cSub = [self labelAlpha:0.65];
        _cPlay = NBButton(@"pause.fill", 14);
        _cPlay.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
        _cPlay.clipsToBounds = YES;
        [_cPlay addTarget:self action:@selector(tapPlay) forControlEvents:UIControlEventTouchUpInside];
        _cPrev = NBButton(@"backward.fill", 12);
        _cNext = NBButton(@"forward.fill", 12);
        [_cPrev addTarget:self action:@selector(tapPrev) forControlEvents:UIControlEventTouchUpInside];
        [_cNext addTarget:self action:@selector(tapNext) forControlEvents:UIControlEventTouchUpInside];
        for (UIView *v in @[_cArt, _cRing, _cTitle, _cSub, _cPrev, _cNext, _cPlay]) [_collapsedBox addSubview:v];

        // expanded
        _eArt = [UIImageView new];
        _eArt.clipsToBounds = YES;
        _eArt.tintColor = [UIColor whiteColor];
        _eTitle = [self labelAlpha:1];
        _eTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        _eSub = [self labelAlpha:0.65];
        _eSub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _eBig = [UILabel new];
        _eBig.textColor = [UIColor whiteColor];
        _eBig.adjustsFontSizeToFitWidth = YES;
        _eTimeL = [self labelAlpha:0.6];
        _eTimeL.font = NBMono(11, UIFontWeightMedium);
        _eTimeR = [self labelAlpha:0.6];
        _eTimeR.font = NBMono(11, UIFontWeightMedium);
        _eTimeR.textAlignment = NSTextAlignmentRight;
        _eEq = [NBEQView new];
        _eTrack = [UIView new];
        _eTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
        _eTrack.layer.cornerRadius = 2;
        _eTrack.clipsToBounds = YES;
        _eFill = [UIView new];
        _eFill.backgroundColor = [UIColor whiteColor];
        [_eTrack addSubview:_eFill];

        _ePrev = NBButton(@"backward.fill", 22);
        _ePlay = NBButton(@"pause.fill", 30);
        _eNext = NBButton(@"forward.fill", 22);
        _eToggle = NBButton(@"pause.fill", 22);
        _eStop = NBButton(@"xmark", 20);
        _eToggle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _eStop.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _eToggle.layer.cornerRadius = 22;
        _eStop.layer.cornerRadius = 22;
        [_ePrev addTarget:self action:@selector(tapPrev) forControlEvents:UIControlEventTouchUpInside];
        [_ePlay addTarget:self action:@selector(tapPlay) forControlEvents:UIControlEventTouchUpInside];
        [_eNext addTarget:self action:@selector(tapNext) forControlEvents:UIControlEventTouchUpInside];
        [_eToggle addTarget:self action:@selector(tapToggle) forControlEvents:UIControlEventTouchUpInside];
        [_eStop addTarget:self action:@selector(tapStop) forControlEvents:UIControlEventTouchUpInside];

        for (UIView *v in @[_eArt, _eTitle, _eSub, _eBig, _eTimeL, _eTimeR, _eEq, _eTrack, _ePrev, _ePlay, _eNext, _eToggle, _eStop]) {
            [_expandedBox addSubview:v];
        }
        [self applyStyle];
    }
    return self;
}

- (void)tapPrev { if (self.onPrev) self.onPrev(); }
- (void)tapPlay {
    // on status cards the trailing button runs the card's own action (e.g. flashlight off)
    if (_item.type == NBItemTypeStatus) { if (_item.action) _item.action(); return; }
    if (_item.type == NBItemTypeTimer) { [self tapToggle]; return; }
    if (self.onPlay) self.onPlay();
}
- (void)tapNext { if (self.onNext) self.onNext(); }
- (void)tapToggle { if (self.onTimerToggle) self.onTimerToggle(); }
- (void)tapStop { if (self.onTimerStop) self.onTimerStop(); }

#pragma mark Style

- (void)setCornerRadius:(CGFloat)cornerRadius {
    _cornerRadius = cornerRadius;
    _blur.layer.cornerRadius = cornerRadius;
}

- (CGFloat)cornerRadius { return _cornerRadius; }

- (void)applyStyle {
    NBSettings *st = [NBSettings shared];
    if (!_styleInit || _blurOn != st.useBlur) {
        _blur.effect = st.useBlur ? [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark] : nil;
        _blurOn = st.useBlur;
        _styleInit = YES;
    }
    UIColor *base = (st.artTint && _item.tint) ? NBLighten(_item.tint, st.capsuleShade * 0.8) : [UIColor colorWithWhite:st.capsuleShade alpha:1];
    _blur.contentView.backgroundColor = [base colorWithAlphaComponent:st.bgOpacity];
}

#pragma mark Press feedback

- (void)setPressed:(BOOL)pressed {
    [UIView animateWithDuration:pressed ? 0.12 : 0.4
                          delay:0
         usingSpringWithDamping:pressed ? 1.0 : 0.55
          initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self->_host.transform = pressed ? CGAffineTransformMakeScale(0.965, 0.965) : CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [self setPressed:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self setPressed:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self setPressed:NO];
}

#pragma mark Boxes

- (void)setCollapsedSize:(CGSize)cs expandedSize:(CGSize)es {
    _cs = cs;
    _es = es;
    if (_item) {
        [self layoutCollapsedContent];
        [self layoutExpandedContent];
    }
}

- (void)layoutBoxesExpanded:(BOOL)expanded {
    CGFloat cw = _cs.width, ch = _cs.height, ew = _es.width, eh = _es.height;
    if (expanded) {
        _expandedBox.frame = CGRectMake(0, 0, ew, eh);
        _collapsedBox.frame = CGRectMake((ew - cw) / 2, eh - ch, cw, ch);
    } else {
        _collapsedBox.frame = CGRectMake(0, 0, cw, ch);
        _expandedBox.frame = CGRectMake((cw - ew) / 2, 0, ew, eh);
    }
}

- (void)setBoxAlphasExpanded:(BOOL)expanded backdrop:(BOOL)backdrop {
    _collapsedBox.alpha = (expanded || backdrop) ? 0 : 1;
    _expandedBox.alpha = expanded ? 1 : 0;
}

#pragma mark Content

- (void)configure:(NBItem *)item {
    _item = item;
    [UIView animateWithDuration:NBD(0.35) animations:^{ [self applyStyle]; }];
    BOOL media = item.type == NBItemTypeMedia;
    BOOL timer = item.type == NBItemTypeTimer;
    BOOL stopwatch = item.type == NBItemTypeStopwatch;
    BOOL status = item.type == NBItemTypeStatus;
    BOOL counter = timer || stopwatch;           // big ticking number
    BOOL hasAction = status && item.action != nil;

    // collapsed
    _cArt.hidden = !media;
    _cRing.hidden = media;
    _cPlay.hidden = !(media || hasAction || timer);
    _cPrev.hidden = _cNext.hidden = !media;
    _cTitle.text = item.title;
    if (media) {
        if (item.artwork) {
            _cArt.image = item.artwork;
            _cArt.contentMode = UIViewContentModeScaleAspectFill;
            _cArt.backgroundColor = [UIColor clearColor];
        } else {
            _cArt.image = NBSym(@"music.note", 16);
            _cArt.contentMode = UIViewContentModeCenter;
            _cArt.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
        }
        _cSub.text = item.subtitle;
        _cTitle.textColor = [UIColor whiteColor];
        _cSub.textColor = [UIColor colorWithWhite:1 alpha:0.65];
        [_cPlay setImage:NBSym(item.playing ? @"pause.fill" : @"play.fill", 14) forState:UIControlStateNormal];
    } else {
        NSString *glyph = timer ? @"hourglass" : stopwatch ? @"stopwatch.fill" : status ? (item.symbol ?: @"circle.fill") : @"alarm.fill";
        [_cRing setGlyph:glyph];
        [_cRing setPlain:status];
        [_cRing setBare:!status];
        [_cRing setAccent:status ? item.accent : NBBlue()];
        _cTitle.textColor = [UIColor colorWithWhite:1 alpha:0.85];
        _cSub.textColor = [UIColor whiteColor];
        if (timer) [_cPlay setImage:NBSym(item.paused ? @"play.fill" : @"pause.fill", 14) forState:UIControlStateNormal];
        if (status) {
            _cSub.text = item.subtitle;
            if (hasAction) [_cPlay setImage:NBSym(item.actionSymbol ?: @"xmark", 14) forState:UIControlStateNormal];
        }
    }

    // expanded
    _eArt.hidden = counter;
    _eSub.hidden = counter;
    _eEq.hidden = !media;
    _eTrack.hidden = _eTimeL.hidden = _eTimeR.hidden = !media;
    _ePrev.hidden = _ePlay.hidden = _eNext.hidden = !media;
    _eBig.hidden = media || status;
    _eToggle.hidden = _eStop.hidden = !timer;

    _eTitle.text = item.title;
    _eSub.text = item.subtitle;
    _eTitle.textAlignment = counter ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    _eBig.textAlignment = counter ? NSTextAlignmentCenter : NSTextAlignmentRight;
    _eBig.font = counter ? NBMono(46, UIFontWeightLight) : NBMono(34, UIFontWeightMedium);

    if (media) {
        if (item.artwork) {
            _eArt.image = item.artwork;
            _eArt.contentMode = UIViewContentModeScaleAspectFill;
            _eArt.backgroundColor = [UIColor clearColor];
        } else {
            _eArt.image = NBSym(@"music.note", 24);
            _eArt.contentMode = UIViewContentModeCenter;
            _eArt.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
        }
        _eArt.layer.cornerRadius = 10;
        [_eEq setPlaying:item.playing];
        [_ePlay setImage:NBSym(item.playing ? @"pause.fill" : @"play.fill", 30) forState:UIControlStateNormal];
    } else if (timer) {
        [_eToggle setImage:NBSym(item.paused ? @"play.fill" : @"pause.fill", 22) forState:UIControlStateNormal];
    } else if (stopwatch) {
        // nothing extra: the expanded stopwatch only shows the time
    } else if (status) {
        _eArt.image = NBSym(item.symbol ?: @"circle.fill", 22);
        _eArt.contentMode = UIViewContentModeCenter;
        _eArt.backgroundColor = [(item.accent ?: NBAccent()) colorWithAlphaComponent:0.25];
        _eArt.tintColor = item.accent ?: NBAccent();
        _eArt.layer.cornerRadius = 24;
    } else {
        _eArt.image = NBSym(@"alarm.fill", 22);
        _eArt.contentMode = UIViewContentModeCenter;
        _eArt.backgroundColor = NBBlue();
        _eArt.layer.cornerRadius = 24;
    }

    [self layoutCollapsedContent];
    [self layoutExpandedContent];
    [self tick];
}

- (void)layoutCollapsedContent {
    if (!_item) return;
    CGFloat w = _cs.width, h = _cs.height;
    CGFloat u = h / 58.0;
    BOOL media = _item.type == NBItemTypeMedia;
    BOOL status = _item.type == NBItemTypeStatus;
    BOOL timerBtn = _item.type == NBItemTypeTimer;
    BOOL hasAction = (status && _item.action != nil) || timerBtn;
    NBSettings *cst = [NBSettings shared];
    CGFloat padX = cst.contentPadX;
    CGFloat padY = cst.contentPadY;
    CGFloat icon = MAX(14, h - 2 * padY);
    CGFloat iconY = (h - icon) / 2;
    CGFloat btn = 30 * u;

    _cArt.frame = CGRectMake(padX, iconY, icon, icon);
    _cArt.layer.cornerRadius = icon * 0.24;
    _cRing.frame = CGRectMake(padX, iconY, icon, icon);

    CGFloat tx = padX + icon + 9 * u;
    CGFloat edge = MAX(4, padX * 0.8);   // right padding: a bit tighter so the controls fit
    CGFloat right = padX;

    if (media) {
        CGFloat side = 24 * u;
        BOOL wantSides = [NBSettings shared].collapsedControls;
        CGFloat withSides = 2 * side + btn + edge + 4 * u;
        // text must keep a usable width, otherwise prev / next are dropped
        BOOL sides = wantSides && (w - tx - withSides) >= 40 * u;
        right = sides ? withSides : (btn + padX + 6 * u);
        CGFloat playX = sides ? (w - edge - side - btn) : (w - padX - btn);
        _cPlay.frame = CGRectMake(playX, (h - btn) / 2, btn, btn);
        _cPlay.layer.cornerRadius = btn / 2;
        _cPrev.hidden = _cNext.hidden = !sides;
        if (sides) {
            _cPrev.frame = CGRectMake(playX - side, (h - btn) / 2, side, btn);
            _cNext.frame = CGRectMake(playX + btn, (h - btn) / 2, side, btn);
            [_cPrev setImage:NBSym(@"backward.fill", 12 * u) forState:UIControlStateNormal];
            [_cNext setImage:NBSym(@"forward.fill", 12 * u) forState:UIControlStateNormal];
        }
        CGFloat tw = MAX(0, w - tx - right);
        _cTitle.font = [UIFont systemFontOfSize:13 * u weight:UIFontWeightSemibold];
        _cSub.font = [UIFont systemFontOfSize:11 * u weight:UIFontWeightRegular];
        _cTitle.frame = CGRectMake(tx, h / 2 - 16 * u, tw, 16 * u);
        _cSub.frame = CGRectMake(tx, h / 2 + 1 * u, tw, 14 * u);
        return;
    }

    if (hasAction) {
        right = btn + padX + 6 * u;
        _cPlay.frame = CGRectMake(w - padX - btn, (h - btn) / 2, btn, btn);
        _cPlay.layer.cornerRadius = btn / 2;
        _cPlay.backgroundColor = timerBtn ? NBBlueSolid() : [UIColor colorWithWhite:1 alpha:0.18];   // solid blue like ColorOS timers
        _cPlay.clipsToBounds = YES;
    }
    CGFloat tw = MAX(0, w - tx - right);
    // ColorOS order: the value (time) is the bold first line, the label sits under it
    _cSub.font = status ? [UIFont systemFontOfSize:17 * u weight:UIFontWeightBold] : NBMono(18 * u, UIFontWeightBold);
    _cTitle.font = [UIFont systemFontOfSize:13 * u weight:UIFontWeightRegular];
    _cSub.adjustsFontSizeToFitWidth = YES;
    _cSub.minimumScaleFactor = 0.6;
    _cSub.frame = CGRectMake(tx, h / 2 - 20 * u, tw, 22 * u);
    _cTitle.frame = CGRectMake(tx, h / 2 + 2 * u, tw, 17 * u);
}

- (void)layoutExpandedContent {
    if (!_item) return;
    CGFloat w = _es.width, h = _es.height;
    CGFloat m = 12 + 0.5 * [NBSettings shared].contentPadX;   // 20 at the default padding
    switch (_item.type) {
        case NBItemTypeMedia: {
            _eArt.frame = CGRectMake(m, 16, 56, 56);
            _eTitle.frame = CGRectMake(m + 68, 18, w - m - 68 - 52, 22);
            _eSub.frame = CGRectMake(m + 68, 42, w - m - 68 - 52, 18);
            _eEq.frame = CGRectMake(w - m - 18, 22, 18, 16);
            _eTrack.frame = CGRectMake(m, 88, w - 2 * m, 4);
            _eTimeL.frame = CGRectMake(m, 96, 60, 14);
            _eTimeR.frame = CGRectMake(w - m - 60, 96, 60, 14);
            CGFloat cy = h - 26;
            _ePrev.frame = CGRectMake(w / 2 - 70 - 22, cy - 22, 44, 44);
            _ePlay.frame = CGRectMake(w / 2 - 22, cy - 22, 44, 44);
            _eNext.frame = CGRectMake(w / 2 + 70 - 22, cy - 22, 44, 44);
            break;
        }
        case NBItemTypeStopwatch:
            _eTitle.frame = CGRectMake(m, 14, w - 2 * m, 18);
            _eBig.frame = CGRectMake(m, 36, w - 2 * m, 56);
            break;
        case NBItemTypeTimer:
            _eTitle.frame = CGRectMake(m, 14, w - 2 * m, 18);
            _eBig.frame = CGRectMake(m, 34, w - 2 * m, 54);
            _eToggle.frame = CGRectMake(w / 2 - 40 - 22, h - 14 - 44, 44, 44);
            _eStop.frame = CGRectMake(w / 2 + 40 - 22, h - 14 - 44, 44, 44);
            break;
        default:
            _eArt.frame = CGRectMake(m, 22, 48, 48);
            _eTitle.frame = CGRectMake(m + 64, 24, w - m - 64 - 130, 22);
            _eSub.frame = CGRectMake(m + 64, 48, w - m - 64 - 130, 18);
            _eBig.frame = CGRectMake(w - m - 120, 20, 120, 52);
            break;
    }
}

- (void)tick {
    if (!_item) return;
    NSDate *now = [NSDate date];
    switch (_item.type) {
        case NBItemTypeMedia: {
            double el = _item.elapsed;
            if (_item.playing) el += [now timeIntervalSinceDate:_item.refDate] * _item.rate;
            if (_item.duration > 0) el = MIN(el, _item.duration);
            el = MAX(0, el);
            CGFloat frac = _item.duration > 0 ? (CGFloat)(el / _item.duration) : 0;
            _eFill.frame = CGRectMake(0, 0, _eTrack.bounds.size.width * frac, 4);
            _eTimeL.text = NBFmt(el);
            _eTimeR.text = _item.duration > 0 ? NBFmt(_item.duration) : @"--:--";
            break;
        }
        case NBItemTypeTimer: {
            NSTimeInterval rem = _item.paused ? _item.remaining : MAX(0, [_item.refDate timeIntervalSinceDate:now]);
            NSString *t = NBFmt(ceil(rem));
            _cSub.text = t;
            _eBig.text = t;
            _cRing.progress = _item.duration > 0 ? (CGFloat)(rem / _item.duration) : 1;
            break;
        }
        case NBItemTypeStopwatch: {
            double el = _item.elapsed;
            if (_item.playing) el += [now timeIntervalSinceDate:_item.refDate];
            el = MAX(0, el);
            NSString *t = NBFmt(el);
            _cSub.text = t;
            _eBig.text = t;
            _cRing.progress = (CGFloat)(fmod(el, 60.0) / 60.0);
            break;
        }
        case NBItemTypeStatus:
            break;
        default: {
            NSString *t = NBClock(_item.refDate);
            _cSub.text = t;
            _eBig.text = t;
            _cRing.progress = 1;
            break;
        }
    }
}

@end

#pragma mark - Lock screen button (beside the capsule)

@interface NBLockButton : UIView
@property (nonatomic, copy) NSString *action;
@property (nonatomic, copy) NSString *customBundle;
- (void)reload;
- (void)refreshState;
- (void)restyle;
@end

@implementation NBLockButton {
    UIVisualEffectView *_blur;
    UIImageView *_glyph;
    BOOL _active;
    BOOL _styleInit;
    NSString *_shownAction;
    CGFloat _shownSize;
    UIImpactFeedbackGenerator *_haptic;
    UIView *_pressOverlay;
    BOOL _pressed;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blur.clipsToBounds = YES;
        _blur.layer.cornerCurve = kCACornerCurveContinuous;
        _blur.layer.borderWidth = 1.0;
        _blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
        [self addSubview:_blur];
        _glyph = [UIImageView new];
        _glyph.contentMode = UIViewContentModeCenter;
        _pressOverlay = [UIView new];
        _pressOverlay.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
        _pressOverlay.alpha = 0;
        _pressOverlay.userInteractionEnabled = NO;
        [_blur.contentView addSubview:_pressOverlay];
        [_blur.contentView addSubview:_glyph];
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
        [self addGestureRecognizer:tap];
        UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(held:)];
        hold.minimumPressDuration = 0.55;
        [self addGestureRecognizer:hold];
        [self applyStyleAnimated:NO];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // bounds + centre (not frame): _blur carries the press-scale transform
    CGSize sz = self.bounds.size;
    _blur.bounds = CGRectMake(0, 0, sz.width, sz.height);
    _blur.center = CGPointMake(sz.width / 2, sz.height / 2);
    _blur.layer.cornerRadius = sz.width / 2;
    _glyph.frame = _blur.bounds;
    _pressOverlay.frame = _blur.bounds;
    if (_shownSize != self.bounds.size.width) [self reload];
}

- (void)applyStyleAnimated:(BOOL)animated {
    void (^apply)(void) = ^{
        // iOS style: dark glass when off, bright white disc with a dark glyph when on
        NBSettings *st = [NBSettings shared];
        self->_blur.contentView.backgroundColor = self->_active ? [UIColor colorWithRed:1.0 green:0.97 blue:0.88 alpha:0.95] : [UIColor colorWithWhite:st.btnShade alpha:st.btnOpacity];
        self->_glyph.tintColor = self->_active ? [UIColor colorWithWhite:0.08 alpha:1] : [UIColor whiteColor];
    };
    if (animated) [UIView animateWithDuration:0.25 animations:apply]; else apply();
}

- (void)reload {
    CGFloat w = self.bounds.size.width;
    _shownSize = w;
    _shownAction = self.action;
    _active = [NBActions isActive:self.action];
    _glyph.image = [NBSym([NBActions symbolForAction:self.action active:_active] ?: @"questionmark", MAX(12, w * 0.40)) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [self applyStyleAnimated:NO];
}

- (void)setAction:(NSString *)action {
    if ([_action isEqualToString:action]) return;
    _action = [action copy];
    [self reload];
}

- (void)refreshState {
    if (![NBActions isToggle:self.action]) return;
    BOOL now = [NBActions isActive:self.action];
    if (now == _active) return;
    _active = now;
    _glyph.image = [NBSym([NBActions symbolForAction:self.action active:_active] ?: @"questionmark", MAX(12, self.bounds.size.width * 0.40)) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [self applyStyleAnimated:YES];
}

- (void)restyle { [self applyStyleAnimated:YES]; }

// Press feedback: the disc shrinks and brightens under the finger, then springs back with a little bounce.
- (void)setPressed:(BOOL)pressed {
    if (pressed == _pressed) return;
    _pressed = pressed;
    [UIView animateWithDuration:pressed ? 0.14 : 0.55 delay:0
         usingSpringWithDamping:pressed ? 1.0 : 0.42 initialSpringVelocity:pressed ? 0 : 10
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self->_blur.transform = pressed ? CGAffineTransformMakeScale(0.84, 0.84) : CGAffineTransformIdentity;
        self->_pressOverlay.alpha = pressed ? 1 : 0;
        self->_glyph.transform = pressed ? CGAffineTransformMakeScale(0.9, 0.9) : CGAffineTransformIdentity;
    } completion:nil];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [self setPressed:YES];
    if ([NBSettings shared].haptics) [_haptic prepare];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self setPressed:NO];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self setPressed:NO];
}

// A "needs long press" button answers a plain tap with a small shake.
- (void)shake {
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    a.values = @[@0, @-5, @5, @-3, @3, @0];
    a.duration = 0.32;
    [_blur.layer addAnimation:a forKey:@"shake"];
}

- (void)run {
    if ([NBSettings shared].haptics) [_haptic impactOccurred];
    [NBActions perform:self.action customBundle:self.customBundle];
    // state changes (Wi-Fi, flashlight ...) land a moment later
    [self performSelector:@selector(refreshState) withObject:nil afterDelay:0.4];
    [self performSelector:@selector(refreshState) withObject:nil afterDelay:1.2];
}

- (void)tapped {
    if ([NBActions requiresHold:self.action]) { [self shake]; return; }   // needs a long press
    [self run];
}

- (void)held:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && [NBActions requiresHold:self.action]) [self run];
}

@end

#pragma mark - Bar (card stack)

@implementation NBBarView {
    NSMutableDictionary<NSString *, NBCardView *> *_cards;
    NSArray<NBItem *> *_items;
    NSInteger _index;
    BOOL _isExpanded;
    BOOL _suppressed;
    CFTimeInterval _clearSince;
    CAShapeLayer *_arcL, *_arcR;   // the "(" ")" marks beside the capsule
    UIView *_cardLayer;            // holds all cards, so the whole stack can slide away as one
    CADisplayLink *_suppressLink;
    NSTimer *_tick;
    CGSize _lastSize;
    UIImpactFeedbackGenerator *_haptic;
    UISelectionFeedbackGenerator *_selection;
    NBLockButton *_btnL, *_btnR;
    int _btnTick;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cards = [NSMutableDictionary dictionary];
        _items = @[];
        _btnL = [[NBLockButton alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
        _btnR = [[NBLockButton alloc] initWithFrame:CGRectMake(0, 0, 52, 52)];
        _btnL.hidden = _btnR.hidden = YES;
        [self addSubview:_btnL];
        [self addSubview:_btnR];
        _cardLayer = [[UIView alloc] initWithFrame:self.bounds];
        _cardLayer.backgroundColor = [UIColor clearColor];
        _cardLayer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cardLayer.userInteractionEnabled = YES;    // (the bar hit-tests its cards itself, see hitTest:)
        [self addSubview:_cardLayer];
        _arcL = [CAShapeLayer layer];
        _arcR = [CAShapeLayer layer];
        for (CAShapeLayer *a in @[_arcL, _arcR]) {
            a.fillColor = nil;
            a.strokeColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
            a.lineWidth = 2.2;
            a.lineCap = kCALineCapRound;
            a.opacity = 0;
            [_cardLayer.layer addSublayer:a];
        }
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        _selection = [[UISelectionFeedbackGenerator alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemsChanged) name:NBItemsChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:NBSettingsChangedNotification object:nil];
    }
    return self;
}

#pragma mark Geometry

- (CGSize)collapsedSize {
    NBSettings *st = [NBSettings shared];
    return CGSizeMake(st.capsuleWidth, st.capsuleHeight);
}

- (CGSize)expandedSizeForItem:(NBItem *)item {
    return CGSizeMake(MIN(self.bounds.size.width - 32, 420), [NBCardView expandedHeightForItem:item]);
}

- (CGRect)placeSize:(CGSize)sz {
    NBSettings *st = [NBSettings shared];
    CGSize b = self.bounds.size;
    CGFloat x = (b.width - sz.width) / 2 + st.xOffset;
    x = MAX(4, MIN(x, b.width - sz.width - 4));
    CGFloat y = b.height - st.bottomOffset - sz.height;
    y = MAX(20, MIN(y, b.height - sz.height));
    return CGRectMake(x, y, sz.width, sz.height);
}

- (NBItem *)currentItem {
    if (_index < 0 || _index >= (NSInteger)_items.count) return nil;
    return _items[_index];
}

#pragma mark Hit testing

// Menus (search, widgets, notification history, passcode, keyboard) take the screen: the capsule slides down
// and the side buttons slide out to the sides. They come back when the screen is clear again.
- (void)checkSuppressed { [self checkSuppressedAnimated:YES]; }

- (void)linkFired:(CADisplayLink *)link { [self checkSuppressedAnimated:YES]; }

- (void)checkSuppressedAnimated:(BOOL)animated {
    NBSettings *st = [NBSettings shared];
    BOOL want = st.enabled && st.hideOnPasscode && self.suppressProbe && self.suppressProbe();
    CFTimeInterval now = CACurrentMediaTime();
    if (!want && _suppressed) {
        // the screen must stay clear for a moment before the bar returns (avoids flicker)
        if (_clearSince == 0) _clearSince = now;
        if (now - _clearSince < 0.5) return;
    } else {
        _clearSince = 0;
    }
    if (want == _suppressed) return;
    _suppressed = want;
    if (want) {
        _isExpanded = NO;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleCollapse) object:nil];
    }
    [self applySuppressionAnimated:animated];
}

- (void)applySuppressionAnimated:(BOOL)animated {
    BOOL hide = _suppressed;
    CGSize b = self.bounds.size;
    CGFloat screenH = MAX(b.height, [UIScreen mainScreen].bounds.size.height);
    CGRect F = [self placeSize:[self collapsedSize]];
    // one common distance: capsule, arcs and both buttons all drop below the screen edge together
    CGFloat dy = screenH - MIN(F.origin.y, screenH) + 80;
    void (^apply)(void) = ^{
        CGAffineTransform t = hide ? CGAffineTransformMakeTranslation(0, dy) : CGAffineTransformIdentity;
        self->_cardLayer.transform = t;
        self->_btnL.transform = t;
        self->_btnR.transform = t;
    };
    if (hide) [self layoutStackAnimated:animated];   // collapses an expanded card on the way out
    if (!animated) { apply(); return; }
    if (hide) {
        // immediate: short ease-out, starts this very frame
        [UIView animateWithDuration:0.26 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseIn
                         animations:apply completion:nil];
    } else {
        [UIView animateWithDuration:NBD(0.55) delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:apply completion:nil];
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_suppressed) return nil;
    for (NBLockButton *b in @[_btnL, _btnR]) {
        if (b.hidden || b.alpha < 0.05) continue;
        CGPoint bp = [self convertPoint:point toView:b];
        if ([b pointInside:bp withEvent:event]) return [b hitTest:bp withEvent:event];
    }
    NSInteger n = (NSInteger)_items.count;
    for (NSInteger d = 0; d < n; d++) {
        if (_isExpanded && d > 0) break;
        NBCardView *c = _cards[_items[(_index + d) % n].key];
        if (!c || c.alpha < 0.05) continue;
        CGPoint p = [self convertPoint:point toView:c];
        if ([c pointInside:p withEvent:event]) return [c hitTest:p withEvent:event];
    }
    return nil;
}

#pragma mark Lifecycle

- (void)setActive:(BOOL)active {
    [[NBDataSource shared] setPolling:active];
    [_tick invalidate];
    _tick = nil;
    [_suppressLink invalidate];
    _suppressLink = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleCollapse) object:nil];
    if (!active && _suppressed) {   // next time the lock screen appears, start from a clean state
        _suppressed = NO;
        _clearSince = 0;
        [self applySuppressionAnimated:NO];
    }
    if (active) {
        _tick = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tickFired) userInfo:nil repeats:YES];
        _suppressLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(linkFired:)];
        [_suppressLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        [self layoutLockButtonsAnimated:NO];
        _clearSince = 0;
        [self checkSuppressedAnimated:NO];
        [_btnL refreshState];
        [_btnR refreshState];
        [self itemsChanged];
    } else {
        _isExpanded = NO;
        [self layoutLockButtonsAnimated:NO];
        [self layoutStackAnimated:NO];
    }
}

- (void)tickFired {
    for (NBCardView *c in _cards.allValues) [c tick];
    if (self.tickHook) self.tickHook();
    if ((++_btnTick % 4) == 0) {
        [self layoutLockButtonsAnimated:NO];
        if (!_btnL.hidden) [_btnL refreshState];
        if (!_btnR.hidden) [_btnR refreshState];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutLockButtonsAnimated:NO];
    if (_suppressed && !CGSizeEqualToSize(_lastSize, self.bounds.size)) [self applySuppressionAnimated:NO];
    if (!CGSizeEqualToSize(_lastSize, self.bounds.size)) {
        _lastSize = self.bounds.size;
        if (_items.count) {
            [self refreshCardSizes];
            [self layoutStackAnimated:NO];
        }
    }
}

#pragma mark Lock screen buttons

// The buttons sit beside the collapsed capsule, vertically centred on it, and fade out while a card is expanded.
- (void)layoutLockButtonsAnimated:(BOOL)animated {
    CGSize b = self.bounds.size;
    if (b.width < 50) return;
    NBSettings *st = [NBSettings shared];
    BOOL on = st.enabled && st.btnEnabled;
    BOOL showL = on && ![st.btnLeftAction isEqualToString:@"none"];
    BOOL showR = on && ![st.btnRightAction isEqualToString:@"none"];

    CGRect F = [self placeSize:[self collapsedSize]];
    CGFloat sz = st.btnSize, gap = st.btnGap;
    CGFloat cy = CGRectGetMidY(F);
    CGFloat lx = MAX(4, F.origin.x - gap - sz);
    CGFloat rx = MIN(b.width - sz - 4, CGRectGetMaxX(F) + gap);

    _btnL.customBundle = st.btnLeftApp;
    _btnR.customBundle = st.btnRightApp;
    _btnL.action = st.btnLeftAction;
    _btnR.action = st.btnRightAction;
    // bounds + centre keep working while the buttons carry the slide-away transform
    _btnL.bounds = CGRectMake(0, 0, sz, sz);
    _btnR.bounds = CGRectMake(0, 0, sz, sz);
    _btnL.center = CGPointMake(lx + sz / 2, cy);
    _btnR.center = CGPointMake(rx + sz / 2, cy);

    // "(" and ")" marks in the gaps beside the capsule
    {
        CGFloat ah = F.size.height * 0.5, aw = 6;
        CGFloat gx = MAX(aw + 2, MIN(gap, 40) / 2);
        UIBezierPath *pl = [UIBezierPath bezierPath];
        [pl moveToPoint:CGPointMake(aw, 0)];
        [pl addQuadCurveToPoint:CGPointMake(aw, ah) controlPoint:CGPointMake(-aw * 0.4, ah / 2)];
        UIBezierPath *pr = [UIBezierPath bezierPath];
        [pr moveToPoint:CGPointMake(0, 0)];
        [pr addQuadCurveToPoint:CGPointMake(0, ah) controlPoint:CGPointMake(aw * 1.4, ah / 2)];
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _arcL.path = pl.CGPath;
        _arcR.path = pr.CGPath;
        _arcL.frame = CGRectMake(F.origin.x - gx - aw / 2, cy - ah / 2, aw, ah);
        _arcR.frame = CGRectMake(CGRectGetMaxX(F) + gx - aw / 2, cy - ah / 2, aw, ah);
        BOOL arcs = on && _items.count > 0 && !_isExpanded && (showL || showR);
        _arcL.opacity = (arcs && showL) ? 1 : 0;
        _arcR.opacity = (arcs && showR) ? 1 : 0;
        [CATransaction commit];
    }

    CGFloat target = _isExpanded ? 0 : 1;
    void (^apply)(void) = ^{
        self->_btnL.alpha = showL ? target : 0;
        self->_btnR.alpha = showR ? target : 0;
    };
    _btnL.hidden = !showL;
    _btnR.hidden = !showR;
    if (animated) [UIView animateWithDuration:NBD(0.25) animations:apply]; else apply();
}

#pragma mark Data

- (void)settingsChanged {
    [self layoutLockButtonsAnimated:NO];
    [_btnL restyle];
    [_btnR restyle];
    for (NBCardView *c in _cards.allValues) [c applyStyle];
    [self itemsChanged];
}

- (void)refreshCardSizes {
    CGSize cs = [self collapsedSize];
    for (NBItem *it in _items) {
        NBCardView *c = _cards[it.key];
        [c setCollapsedSize:cs expandedSize:[self expandedSizeForItem:it]];
    }
}

- (NBCardView *)makeCardForItem:(NBItem *)item {
    NBCardView *c = [[NBCardView alloc] initWithFrame:CGRectMake(0, 0, [self collapsedSize].width, [self collapsedSize].height)];
    __weak typeof(self) ws = self;
    c.onPrev = ^{ [[NBDataSource shared] mediaCommand:5]; [ws scheduleIdleCollapse]; };
    c.onPlay = ^{ [[NBDataSource shared] mediaCommand:2]; [ws scheduleIdleCollapse]; };
    c.onNext = ^{ [[NBDataSource shared] mediaCommand:4]; [ws scheduleIdleCollapse]; };
    c.onTimerToggle = ^{ [[NBDataSource shared] toggleTimer:[ws currentItem]]; [ws scheduleIdleCollapse]; };
    c.onTimerStop = ^{ [[NBDataSource shared] stopTimer:[ws currentItem]]; [ws scheduleIdleCollapse]; };

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [c addGestureRecognizer:tap];
    for (NSNumber *dir in @[@(UISwipeGestureRecognizerDirectionUp), @(UISwipeGestureRecognizerDirectionDown)]) {
        UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
        sw.direction = (UISwipeGestureRecognizerDirection)dir.integerValue;
        [c addGestureRecognizer:sw];
    }

    // enter state: small, low and transparent; the stack layout animates it in
    CGRect F = [self placeSize:[self collapsedSize]];
    c.center = CGPointMake(CGRectGetMidX(F), CGRectGetMidY(F));
    c.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.6, 0.6), CGAffineTransformMakeTranslation(0, 22));
    c.alpha = 0;
    c.cornerRadius = [self collapsedSize].height / 2 * [NBSettings shared].cornerRadius;
    [_cardLayer addSubview:c];
    return c;
}

- (void)itemsChanged {
    NBSettings *st = [NBSettings shared];
    NSArray<NBItem *> *items = st.enabled ? [NBDataSource shared].items : @[];
    NSString *curKey = [self currentItem].key;
    NSSet *oldKeys = [NSSet setWithArray:_cards.allKeys];
    NSMutableSet *newKeys = [NSMutableSet set];
    for (NBItem *it in items) [newKeys addObject:it.key];

    BOOL structural = NO;

    for (NSString *k in oldKeys) {
        if ([newKeys containsObject:k]) continue;
        structural = YES;
        NBCardView *dead = _cards[k];
        [_cards removeObjectForKey:k];
        [UIView animateWithDuration:NBD(0.28) delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            dead.alpha = 0;
            dead.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.7, 0.7), CGAffineTransformMakeTranslation(0, 18));
        } completion:^(BOOL finished) {
            [dead removeFromSuperview];
        }];
    }

    _items = items;
    if (!items.count) {
        _isExpanded = NO;
        [self layoutLockButtonsAnimated:YES];
        _index = 0;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleCollapse) object:nil];
        return;
    }

    NSString *wantKey = curKey;
    for (NBItem *it in items) {
        if (![oldKeys containsObject:it.key]) {
            structural = YES;
            if (!_isExpanded) wantKey = it.key;
        }
    }
    _index = 0;
    if (wantKey) {
        for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
            if ([items[i].key isEqualToString:wantKey]) { _index = i; break; }
        }
    }

    CGSize cs = [self collapsedSize];
    for (NBItem *it in items) {
        NBCardView *c = _cards[it.key];
        if (!c) {
            c = [self makeCardForItem:it];
            _cards[it.key] = c;
        }
        [c setCollapsedSize:cs expandedSize:[self expandedSizeForItem:it]];
        [c configure:it];
        [c layoutBoxesExpanded:(_isExpanded && [it.key isEqualToString:items[_index].key])];
    }

    [self layoutStackAnimated:structural];
}

#pragma mark Stack layout

- (void)layoutStackAnimated:(BOOL)animated {
    NSInteger n = (NSInteger)_items.count;
    if (!n) return;

    NBSettings *st = [NBSettings shared];
    CGSize cs = [self collapsedSize];
    CGRect F = [self placeSize:cs];
    CGFloat u = st.capsuleHeight / 58.0;
    CGFloat peek = 9 * u;
    BOOL expandedMode = _isExpanded;

    for (NSInteger i = 0; i < n; i++) {
        NBCardView *c = _cards[_items[i].key];
        NSInteger d = ((i - _index) % n + n) % n;
        c.layer.zPosition = -(CGFloat)d;
    }

    void (^frames)(void) = ^{
        for (NSInteger i = 0; i < n; i++) {
            NBItem *it = self->_items[i];
            NBCardView *c = self->_cards[it.key];
            if (!c) continue;
            NSInteger d = ((i - self->_index) % n + n) % n;
            BOOL exp = (d == 0) && expandedMode;
            CGSize sz = exp ? [self expandedSizeForItem:it] : cs;
            CGRect fr = exp ? [self placeSize:sz] : F;

            c.bounds = CGRectMake(0, 0, sz.width, sz.height);
            c.center = CGPointMake(CGRectGetMidX(fr), CGRectGetMidY(fr));
            if (d == 0) {
                c.transform = CGAffineTransformIdentity;
            } else {
                CGFloat dd = (CGFloat)MIN(d, 2);
                CGFloat s = 1 - 0.065 * dd;
                CGFloat ty = -(sz.height * (1 - s)) / 2 - peek * dd;
                c.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(s, s), CGAffineTransformMakeTranslation(0, ty));
            }
            if (d == 0) c.alpha = 1;
            else if (expandedMode) c.alpha = 0;
            else c.alpha = (d <= 2) ? (1 - 0.22 * (CGFloat)d) : 0;
            c.cornerRadius = exp ? 26 * st.cornerRadius : sz.height / 2 * st.cornerRadius;
            [c layoutBoxesExpanded:exp];
        }
    };
    void (^fades)(void) = ^{
        for (NSInteger i = 0; i < n; i++) {
            NBCardView *c = self->_cards[self->_items[i].key];
            NSInteger d = ((i - self->_index) % n + n) % n;
            [c setBoxAlphasExpanded:((d == 0) && expandedMode) backdrop:(d != 0)];
        }
    };

    if (animated) {
        [UIView animateWithDuration:NBD(0.6) delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.7
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:frames completion:nil];
        [UIView animateWithDuration:NBD(expandedMode ? 0.28 : 0.2)
                              delay:NBD(expandedMode ? 0.08 : 0)
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:fades completion:nil];
    } else {
        frames();
        fades();
    }
}

#pragma mark Expand / cycle

- (void)setExpanded:(BOOL)expanded {
    if (!_items.count) expanded = NO;
    if (expanded == _isExpanded) return;
    _isExpanded = expanded;
    if (expanded && [NBSettings shared].haptics) [_haptic impactOccurred];
    [self layoutLockButtonsAnimated:YES];
    [self layoutStackAnimated:YES];
    [self scheduleIdleCollapse];
}

- (void)cycle:(NSInteger)dir {
    NSInteger n = (NSInteger)_items.count;
    if (n < 2) return;
    _index = ((_index + dir) % n + n) % n;
    if ([NBSettings shared].haptics) [_selection selectionChanged];
    [self layoutStackAnimated:YES];
    [self scheduleIdleCollapse];
}

- (void)scheduleIdleCollapse {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleCollapse) object:nil];
    if (_isExpanded) [self performSelector:@selector(idleCollapse) withObject:nil afterDelay:10];
}

- (void)idleCollapse {
    [self setExpanded:NO];
}

#pragma mark Gestures

- (void)handleTap:(UITapGestureRecognizer *)g {
    NBCardView *card = (NBCardView *)g.view;
    NBItem *front = [self currentItem];
    if (card.item == front || [card.item.key isEqualToString:front.key]) {
        if (front.type == NBItemTypeStatus) return;   // ambient cards only inform, they do not expand
        [self setExpanded:!_isExpanded];
        return;
    }
    // tapping a card peeking from behind brings it to the front
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        if ([_items[i].key isEqualToString:card.item.key]) {
            _index = i;
            if ([NBSettings shared].haptics) [_selection selectionChanged];
            [self layoutStackAnimated:YES];
            [self scheduleIdleCollapse];
            break;
        }
    }
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)g {
    [self cycle:(g.direction == UISwipeGestureRecognizerDirectionUp) ? 1 : -1];
}

@end
