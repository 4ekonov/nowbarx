#import "NBBarView.h"
#import "NBDataSource.h"
#import "NBSettings.h"

#pragma mark - Helpers

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
@end

@implementation NBRingView {
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
    _glyph.frame = self.bounds;
    if (_glyphName) _glyph.image = NBSym(_glyphName, w * 0.42);
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

    // collapsed content
    UIImageView *_cArt;
    NBRingView *_cRing;
    UILabel *_cTitle, *_cSub;
    UIButton *_cPlay;

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
        _blur.layer.borderWidth = 0.5;
        _blur.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
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
        for (UIView *v in @[_cArt, _cRing, _cTitle, _cSub, _cPlay]) [_collapsedBox addSubview:v];

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
- (void)tapPlay { if (self.onPlay) self.onPlay(); }
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
    _blur.effect = st.useBlur ? [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark] : nil;
    _blur.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:st.bgOpacity];
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
    BOOL media = item.type == NBItemTypeMedia;
    BOOL timer = item.type == NBItemTypeTimer;

    // collapsed
    _cArt.hidden = !media;
    _cRing.hidden = media;
    _cPlay.hidden = !media;
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
        [_cRing setGlyph:timer ? @"timer" : @"alarm.fill"];
        _cTitle.textColor = [UIColor colorWithWhite:1 alpha:0.65];
        _cSub.textColor = [UIColor whiteColor];
    }

    // expanded
    _eArt.hidden = timer;
    _eSub.hidden = timer;
    _eEq.hidden = !media;
    _eTrack.hidden = _eTimeL.hidden = _eTimeR.hidden = !media;
    _ePrev.hidden = _ePlay.hidden = _eNext.hidden = !media;
    _eBig.hidden = media;
    _eToggle.hidden = _eStop.hidden = !timer;

    _eTitle.text = item.title;
    _eSub.text = item.subtitle;
    _eTitle.textAlignment = timer ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    _eBig.textAlignment = timer ? NSTextAlignmentCenter : NSTextAlignmentRight;
    _eBig.font = timer ? NBMono(46, UIFontWeightLight) : NBMono(34, UIFontWeightMedium);

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
    } else {
        _eArt.image = NBSym(@"alarm.fill", 22);
        _eArt.contentMode = UIViewContentModeCenter;
        _eArt.backgroundColor = NBAccent();
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
    CGFloat pad = 8 * u;
    CGFloat icon = h - 2 * pad;
    CGFloat btn = 30 * u;

    _cArt.frame = CGRectMake(pad, pad, icon, icon);
    _cArt.layer.cornerRadius = icon * 0.24;
    _cRing.frame = CGRectMake(pad, pad, icon, icon);

    CGFloat tx = pad + icon + 9 * u;
    CGFloat right = media ? (btn + pad + 4 * u) : pad;
    CGFloat tw = MAX(0, w - tx - right);

    if (media) {
        _cPlay.frame = CGRectMake(w - pad - btn, (h - btn) / 2, btn, btn);
        _cPlay.layer.cornerRadius = btn / 2;
        _cTitle.font = [UIFont systemFontOfSize:13 * u weight:UIFontWeightSemibold];
        _cSub.font = [UIFont systemFontOfSize:11 * u weight:UIFontWeightRegular];
        _cTitle.frame = CGRectMake(tx, h / 2 - 16 * u, tw, 16 * u);
        _cSub.frame = CGRectMake(tx, h / 2 + 1 * u, tw, 14 * u);
    } else {
        _cTitle.font = [UIFont systemFontOfSize:11 * u weight:UIFontWeightMedium];
        _cSub.font = NBMono(21 * u, UIFontWeightSemibold);
        _cTitle.frame = CGRectMake(tx, h / 2 - 19 * u, tw, 14 * u);
        _cSub.frame = CGRectMake(tx, h / 2 - 5 * u, tw, 26 * u);
    }
}

- (void)layoutExpandedContent {
    if (!_item) return;
    CGFloat w = _es.width, h = _es.height;
    switch (_item.type) {
        case NBItemTypeMedia: {
            _eArt.frame = CGRectMake(16, 16, 56, 56);
            _eTitle.frame = CGRectMake(84, 18, w - 84 - 48, 22);
            _eSub.frame = CGRectMake(84, 42, w - 84 - 48, 18);
            _eEq.frame = CGRectMake(w - 16 - 18, 22, 18, 16);
            _eTrack.frame = CGRectMake(16, 88, w - 32, 4);
            _eTimeL.frame = CGRectMake(16, 96, 60, 14);
            _eTimeR.frame = CGRectMake(w - 76, 96, 60, 14);
            CGFloat cy = h - 26;
            _ePrev.frame = CGRectMake(w / 2 - 70 - 22, cy - 22, 44, 44);
            _ePlay.frame = CGRectMake(w / 2 - 22, cy - 22, 44, 44);
            _eNext.frame = CGRectMake(w / 2 + 70 - 22, cy - 22, 44, 44);
            break;
        }
        case NBItemTypeTimer:
            _eTitle.frame = CGRectMake(16, 14, w - 32, 18);
            _eBig.frame = CGRectMake(16, 34, w - 32, 54);
            _eToggle.frame = CGRectMake(w / 2 - 40 - 22, h - 14 - 44, 44, 44);
            _eStop.frame = CGRectMake(w / 2 + 40 - 22, h - 14 - 44, 44, 44);
            break;
        default:
            _eArt.frame = CGRectMake(16, 22, 48, 48);
            _eTitle.frame = CGRectMake(80, 24, w - 80 - 130, 22);
            _eSub.frame = CGRectMake(80, 48, w - 80 - 130, 18);
            _eBig.frame = CGRectMake(w - 16 - 120, 20, 120, 52);
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

#pragma mark - Bar (card stack)

@implementation NBBarView {
    NSMutableDictionary<NSString *, NBCardView *> *_cards;
    NSArray<NBItem *> *_items;
    NSInteger _index;
    BOOL _isExpanded;
    NSTimer *_tick;
    CGSize _lastSize;
    UIImpactFeedbackGenerator *_haptic;
    UISelectionFeedbackGenerator *_selection;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _cards = [NSMutableDictionary dictionary];
        _items = @[];
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

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
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
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleCollapse) object:nil];
    if (active) {
        _tick = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tickFired) userInfo:nil repeats:YES];
        [self itemsChanged];
    } else {
        _isExpanded = NO;
        [self layoutStackAnimated:NO];
    }
}

- (void)tickFired {
    for (NBCardView *c in _cards.allValues) [c tick];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(_lastSize, self.bounds.size)) {
        _lastSize = self.bounds.size;
        if (_items.count) {
            [self refreshCardSizes];
            [self layoutStackAnimated:NO];
        }
    }
}

#pragma mark Data

- (void)settingsChanged {
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
    c.cornerRadius = [self collapsedSize].height / 2;
    [self addSubview:c];
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
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            dead.alpha = 0;
            dead.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.7, 0.7), CGAffineTransformMakeTranslation(0, 18));
        } completion:^(BOOL finished) {
            [dead removeFromSuperview];
        }];
    }

    _items = items;
    if (!items.count) {
        _isExpanded = NO;
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
            c.cornerRadius = exp ? 26 : sz.height / 2;
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
        [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.7
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:frames completion:nil];
        [UIView animateWithDuration:expandedMode ? 0.28 : 0.2
                              delay:expandedMode ? 0.08 : 0
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
