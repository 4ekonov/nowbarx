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

#pragma mark - Collapsed pill content

@interface NBCollapsedView : UIView
- (void)configure:(NBItem *)item;
- (void)tick;
@end

@implementation NBCollapsedView {
    UIImageView *_icon;
    UILabel *_title;
    UILabel *_trailing;
    NBEQView *_eq;
    NBItem *_item;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _icon = [UIImageView new];
        _icon.clipsToBounds = YES;
        _icon.tintColor = [UIColor whiteColor];
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
        _title.textColor = [UIColor whiteColor];
        _trailing = [UILabel new];
        _trailing.font = NBMono(13, UIFontWeightSemibold);
        _trailing.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        _trailing.textAlignment = NSTextAlignmentRight;
        _eq = [NBEQView new];
        for (UIView *v in @[_icon, _title, _trailing, _eq]) [self addSubview:v];
    }
    return self;
}

- (void)configure:(NBItem *)item {
    _item = item;
    switch (item.type) {
        case NBItemTypeMedia:
            if (item.artwork) {
                _icon.image = item.artwork;
                _icon.contentMode = UIViewContentModeScaleAspectFill;
                _icon.backgroundColor = [UIColor clearColor];
            } else {
                _icon.image = NBSym(@"music.note", 14);
                _icon.contentMode = UIViewContentModeCenter;
                _icon.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
            }
            _title.text = item.title;
            _trailing.hidden = YES;
            _eq.hidden = NO;
            [_eq setPlaying:item.playing];
            break;
        case NBItemTypeTimer:
            _icon.image = NBSym(@"timer", 14);
            _icon.contentMode = UIViewContentModeCenter;
            _icon.backgroundColor = [UIColor systemOrangeColor];
            _title.text = item.title;
            _trailing.hidden = NO;
            _eq.hidden = YES;
            break;
        case NBItemTypeAlarm:
            _icon.image = NBSym(@"alarm.fill", 14);
            _icon.contentMode = UIViewContentModeCenter;
            _icon.backgroundColor = [UIColor systemOrangeColor];
            _title.text = item.title;
            _trailing.hidden = NO;
            _eq.hidden = YES;
            break;
    }
    [self tick];
    [self setNeedsLayout];
}

- (void)tick {
    if (!_item) return;
    if (_item.type == NBItemTypeTimer) {
        NSTimeInterval rem = _item.paused ? _item.remaining : MAX(0, [_item.refDate timeIntervalSinceNow]);
        _trailing.text = NBFmt(ceil(rem));
    } else if (_item.type == NBItemTypeAlarm) {
        _trailing.text = NBClock(_item.refDate);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat is = h - 10;
    _icon.frame = CGRectMake(6, (h - is) / 2, is, is);
    _icon.layer.cornerRadius = (_item.type == NBItemTypeMedia) ? is * 0.25 : is / 2;
    CGFloat right = 12;
    if (!_trailing.hidden) {
        _trailing.frame = CGRectMake(w - 12 - 64, 0, 64, h);
        right = 12 + 64 + 4;
    } else if (!_eq.hidden) {
        _eq.frame = CGRectMake(w - 14 - 16, (h - 14) / 2, 16, 14);
        right = 14 + 16 + 8;
    }
    CGFloat tx = 6 + is + 8;
    _title.frame = CGRectMake(tx, 0, MAX(0, w - tx - right), h);
}

@end

#pragma mark - Expanded card content

@interface NBExpandedView : UIView
@property (nonatomic, copy) void (^onPrev)(void);
@property (nonatomic, copy) void (^onPlay)(void);
@property (nonatomic, copy) void (^onNext)(void);
@property (nonatomic, copy) void (^onTimerToggle)(void);
@property (nonatomic, copy) void (^onTimerStop)(void);
+ (CGFloat)heightForItem:(NBItem *)item;
- (void)configure:(NBItem *)item;
- (void)tick;
@end

@implementation NBExpandedView {
    NBItem *_item;
    UIImageView *_art;
    UILabel *_title, *_sub, *_big, *_timeL, *_timeR;
    NBEQView *_eq;
    UIView *_trackBg, *_trackFill;
    UIButton *_prev, *_play, *_next, *_toggle, *_stop;
}

+ (CGFloat)heightForItem:(NBItem *)item {
    switch (item.type) {
        case NBItemTypeMedia: return 150;
        case NBItemTypeTimer: return 140;
        default: return 92;
    }
}

- (UILabel *)labelSize:(CGFloat)size weight:(UIFontWeight)weight alpha:(CGFloat)alpha {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _art = [UIImageView new];
        _art.clipsToBounds = YES;
        _art.tintColor = [UIColor whiteColor];
        _title = [self labelSize:17 weight:UIFontWeightBold alpha:1];
        _sub = [self labelSize:14 weight:UIFontWeightRegular alpha:0.65];
        _big = [UILabel new];
        _big.textColor = [UIColor whiteColor];
        _big.adjustsFontSizeToFitWidth = YES;
        _timeL = [self labelSize:11 weight:UIFontWeightMedium alpha:0.6];
        _timeL.font = NBMono(11, UIFontWeightMedium);
        _timeR = [self labelSize:11 weight:UIFontWeightMedium alpha:0.6];
        _timeR.font = NBMono(11, UIFontWeightMedium);
        _timeR.textAlignment = NSTextAlignmentRight;
        _eq = [NBEQView new];

        _trackBg = [UIView new];
        _trackBg.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
        _trackBg.layer.cornerRadius = 2;
        _trackBg.clipsToBounds = YES;
        _trackFill = [UIView new];
        _trackFill.backgroundColor = [UIColor whiteColor];
        [_trackBg addSubview:_trackFill];

        _prev = NBButton(@"backward.fill", 22);
        _play = NBButton(@"pause.fill", 30);
        _next = NBButton(@"forward.fill", 22);
        _toggle = NBButton(@"pause.fill", 22);
        _stop = NBButton(@"xmark", 20);
        _toggle.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _stop.backgroundColor = [UIColor colorWithWhite:1 alpha:0.18];
        _toggle.layer.cornerRadius = 22;
        _stop.layer.cornerRadius = 22;

        [_prev addTarget:self action:@selector(tapPrev) forControlEvents:UIControlEventTouchUpInside];
        [_play addTarget:self action:@selector(tapPlay) forControlEvents:UIControlEventTouchUpInside];
        [_next addTarget:self action:@selector(tapNext) forControlEvents:UIControlEventTouchUpInside];
        [_toggle addTarget:self action:@selector(tapToggle) forControlEvents:UIControlEventTouchUpInside];
        [_stop addTarget:self action:@selector(tapStop) forControlEvents:UIControlEventTouchUpInside];

        for (UIView *v in @[_art, _title, _sub, _big, _timeL, _timeR, _eq, _trackBg, _prev, _play, _next, _toggle, _stop]) {
            [self addSubview:v];
        }
    }
    return self;
}

- (void)tapPrev { if (self.onPrev) self.onPrev(); }
- (void)tapPlay { if (self.onPlay) self.onPlay(); }
- (void)tapNext { if (self.onNext) self.onNext(); }
- (void)tapToggle { if (self.onTimerToggle) self.onTimerToggle(); }
- (void)tapStop { if (self.onTimerStop) self.onTimerStop(); }

- (void)configure:(NBItem *)item {
    _item = item;
    BOOL media = item.type == NBItemTypeMedia;
    BOOL timer = item.type == NBItemTypeTimer;

    _art.hidden = timer;
    _sub.hidden = timer;
    _eq.hidden = !media;
    _trackBg.hidden = _timeL.hidden = _timeR.hidden = !media;
    _prev.hidden = _play.hidden = _next.hidden = !media;
    _big.hidden = media;
    _toggle.hidden = _stop.hidden = !timer;

    _title.text = item.title;
    _sub.text = item.subtitle;
    _title.textAlignment = timer ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    _big.textAlignment = timer ? NSTextAlignmentCenter : NSTextAlignmentRight;
    _big.font = timer ? NBMono(46, UIFontWeightLight) : NBMono(34, UIFontWeightMedium);

    if (media) {
        if (item.artwork) {
            _art.image = item.artwork;
            _art.contentMode = UIViewContentModeScaleAspectFill;
            _art.backgroundColor = [UIColor clearColor];
        } else {
            _art.image = NBSym(@"music.note", 24);
            _art.contentMode = UIViewContentModeCenter;
            _art.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
        }
        _art.layer.cornerRadius = 10;
        [_eq setPlaying:item.playing];
        [_play setImage:NBSym(item.playing ? @"pause.fill" : @"play.fill", 30) forState:UIControlStateNormal];
    } else if (timer) {
        [_toggle setImage:NBSym(item.paused ? @"play.fill" : @"pause.fill", 22) forState:UIControlStateNormal];
    } else {
        _art.image = NBSym(@"alarm.fill", 22);
        _art.contentMode = UIViewContentModeCenter;
        _art.backgroundColor = [UIColor systemOrangeColor];
        _art.layer.cornerRadius = 24;
    }
    [self setNeedsLayout];
    [self tick];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    switch (_item.type) {
        case NBItemTypeMedia: {
            _art.frame = CGRectMake(16, 16, 56, 56);
            _title.frame = CGRectMake(84, 18, w - 84 - 48, 22);
            _sub.frame = CGRectMake(84, 42, w - 84 - 48, 18);
            _eq.frame = CGRectMake(w - 16 - 18, 22, 18, 16);
            _trackBg.frame = CGRectMake(16, 88, w - 32, 4);
            _timeL.frame = CGRectMake(16, 96, 60, 14);
            _timeR.frame = CGRectMake(w - 76, 96, 60, 14);
            CGFloat cy = h - 26;
            _prev.frame = CGRectMake(w / 2 - 70 - 22, cy - 22, 44, 44);
            _play.frame = CGRectMake(w / 2 - 22, cy - 22, 44, 44);
            _next.frame = CGRectMake(w / 2 + 70 - 22, cy - 22, 44, 44);
            break;
        }
        case NBItemTypeTimer:
            _title.frame = CGRectMake(16, 14, w - 32, 18);
            _big.frame = CGRectMake(16, 34, w - 32, 54);
            _toggle.frame = CGRectMake(w / 2 - 40 - 22, h - 14 - 44, 44, 44);
            _stop.frame = CGRectMake(w / 2 + 40 - 22, h - 14 - 44, 44, 44);
            break;
        default:
            _art.frame = CGRectMake(16, 22, 48, 48);
            _title.frame = CGRectMake(80, 24, w - 80 - 130, 22);
            _sub.frame = CGRectMake(80, 48, w - 80 - 130, 18);
            _big.frame = CGRectMake(w - 16 - 120, 20, 120, 52);
            break;
    }
    [self tick];
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
            _trackFill.frame = CGRectMake(0, 0, _trackBg.bounds.size.width * frac, 4);
            _timeL.text = NBFmt(el);
            _timeR.text = _item.duration > 0 ? NBFmt(_item.duration) : @"--:--";
            break;
        }
        case NBItemTypeTimer: {
            NSTimeInterval rem = _item.paused ? _item.remaining : MAX(0, [_item.refDate timeIntervalSinceDate:now]);
            _big.text = NBFmt(ceil(rem));
            break;
        }
        default:
            _big.text = NBClock(_item.refDate);
            break;
    }
}

@end

#pragma mark - Bar

@implementation NBBarView {
    UIView *_capsule;
    UIVisualEffectView *_blur;
    NBCollapsedView *_collapsed;
    NBExpandedView *_expanded;
    NSArray<NBItem *> *_items;
    NSInteger _index;
    BOOL _isExpanded;
    NSTimer *_tick;
    CGSize _lastSize;
    UIImpactFeedbackGenerator *_haptic;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

        _capsule = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, 40)];
        _capsule.hidden = YES;
        [self addSubview:_capsule];

        _blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        _blur.frame = _capsule.bounds;
        _blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blur.clipsToBounds = YES;
        _blur.layer.cornerRadius = 20;
        _blur.layer.cornerCurve = kCACornerCurveContinuous;
        _blur.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        [_capsule addSubview:_blur];

        _collapsed = [[NBCollapsedView alloc] initWithFrame:_blur.contentView.bounds];
        _collapsed.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_blur.contentView addSubview:_collapsed];

        _expanded = [[NBExpandedView alloc] initWithFrame:CGRectMake(0, 0, 340, 150)];
        _expanded.alpha = 0;
        _expanded.userInteractionEnabled = NO;
        [_blur.contentView addSubview:_expanded];

        __weak typeof(self) ws = self;
        _expanded.onPrev = ^{ [[NBDataSource shared] mediaCommand:5]; [ws scheduleIdleCollapse]; };
        _expanded.onPlay = ^{ [[NBDataSource shared] mediaCommand:2]; [ws scheduleIdleCollapse]; };
        _expanded.onNext = ^{ [[NBDataSource shared] mediaCommand:4]; [ws scheduleIdleCollapse]; };
        _expanded.onTimerToggle = ^{ [[NBDataSource shared] toggleTimer:[ws currentItem]]; [ws scheduleIdleCollapse]; };
        _expanded.onTimerStop = ^{ [[NBDataSource shared] stopTimer:[ws currentItem]]; [ws scheduleIdleCollapse]; };

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)];
        [_capsule addGestureRecognizer:tap];
        for (NSNumber *dir in @[@(UISwipeGestureRecognizerDirectionLeft), @(UISwipeGestureRecognizerDirectionRight), @(UISwipeGestureRecognizerDirectionDown)]) {
            UISwipeGestureRecognizer *sw = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
            sw.direction = dir.integerValue;
            [_capsule addGestureRecognizer:sw];
        }

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(itemsChanged) name:NBItemsChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:NBSettingsChangedNotification object:nil];
    }
    return self;
}

#pragma mark Hit testing

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (_capsule.hidden || _capsule.alpha < 0.05) return nil;
    CGPoint p = [self convertPoint:point toView:_capsule];
    if ([_capsule pointInside:p withEvent:event]) return [_capsule hitTest:p withEvent:event];
    return nil;
}

#pragma mark State

- (NBItem *)currentItem {
    if (_index < 0 || _index >= (NSInteger)_items.count) return nil;
    return _items[_index];
}

- (void)setActive:(BOOL)active {
    [[NBDataSource shared] setPolling:active];
    [_tick invalidate];
    _tick = nil;
    if (active) {
        _tick = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tickFired) userInfo:nil repeats:YES];
        [self itemsChanged];
    } else {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleCollapse) object:nil];
        [self setExpanded:NO animated:NO];
    }
}

- (void)tickFired {
    [_collapsed tick];
    if (_isExpanded) [_expanded tick];
}

- (void)settingsChanged {
    [self itemsChanged];
}

- (void)itemsChanged {
    NBSettings *st = [NBSettings shared];
    NSArray<NBItem *> *items = st.enabled ? [NBDataSource shared].items : @[];
    NSString *curKey = [self currentItem].key;
    _items = items;
    _index = 0;
    if (curKey) {
        NSUInteger i = [items indexOfObjectPassingTest:^BOOL(NBItem *o, NSUInteger idx, BOOL *stop) {
            return [o.key isEqualToString:curKey];
        }];
        if (i != NSNotFound) _index = (NSInteger)i;
    }

    if (!items.count) {
        [self setExpanded:NO animated:NO];
        [self hideAnimated];
        return;
    }

    NBItem *it = [self currentItem];
    [_collapsed configure:it];
    if (_isExpanded) [_expanded configure:it];

    BOOL wasHidden = _capsule.hidden;
    [self relayoutAnimated:!wasHidden];
    if (wasHidden) [self showAnimated];
}

#pragma mark Layout

- (CGRect)frameExpanded:(BOOL)expanded item:(NBItem *)item {
    NBSettings *st = [NBSettings shared];
    CGSize b = self.bounds.size;
    CGFloat w, h;
    if (expanded) {
        w = MIN(b.width - 32, 420);
        h = [NBExpandedView heightForItem:item];
    } else {
        w = 220 * st.scale;
        h = 40 * st.scale;
    }
    CGFloat x = (b.width - w) / 2 + st.xOffset;
    x = MAX(8, MIN(x, b.width - w - 8));
    CGFloat y = b.height - st.bottomOffset - h;
    y = MAX(60, y);
    return CGRectMake(x, y, w, h);
}

- (void)relayoutAnimated:(BOOL)animated {
    NBItem *it = [self currentItem];
    if (!it) return;
    CGRect f = [self frameExpanded:_isExpanded item:it];
    if (_isExpanded) _expanded.frame = CGRectMake(0, 0, f.size.width, f.size.height);
    BOOL expanded = _isExpanded;
    void (^changes)(void) = ^{
        self->_capsule.frame = f;
        self->_blur.layer.cornerRadius = expanded ? 28 : f.size.height / 2;
    };
    if (animated) {
        [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:changes completion:nil];
    } else {
        changes();
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!CGSizeEqualToSize(_lastSize, self.bounds.size)) {
        _lastSize = self.bounds.size;
        if (!_capsule.hidden) [self relayoutAnimated:NO];
    }
}

#pragma mark Show / hide

- (void)showAnimated {
    _capsule.hidden = NO;
    _capsule.alpha = 0;
    _capsule.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [UIView animateWithDuration:0.6 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self->_capsule.alpha = 1;
        self->_capsule.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)hideAnimated {
    if (_capsule.hidden) return;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_capsule.alpha = 0;
        self->_capsule.transform = CGAffineTransformMakeScale(0.85, 0.85);
    } completion:^(BOOL finished) {
        if (!self->_items.count) {
            self->_capsule.hidden = YES;
            self->_capsule.transform = CGAffineTransformIdentity;
        }
    }];
}

#pragma mark Expand / collapse

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    NBItem *it = [self currentItem];
    if (!it) expanded = NO;
    BOOL changed = (expanded != _isExpanded);
    _isExpanded = expanded;
    if (expanded) [_expanded configure:it];
    _expanded.userInteractionEnabled = expanded;
    if (changed && expanded && [NBSettings shared].haptics) [_haptic impactOccurred];

    [self relayoutAnimated:animated];
    void (^fade)(void) = ^{
        self->_collapsed.alpha = expanded ? 0 : 1;
        self->_expanded.alpha = expanded ? 1 : 0;
    };
    if (animated) {
        [UIView animateWithDuration:expanded ? 0.28 : 0.2 delay:expanded ? 0.1 : 0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:fade completion:nil];
    } else {
        fade();
    }
    [self scheduleIdleCollapse];
}

- (void)scheduleIdleCollapse {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(idleCollapse) object:nil];
    if (_isExpanded) [self performSelector:@selector(idleCollapse) withObject:nil afterDelay:10];
}

- (void)idleCollapse {
    [self setExpanded:NO animated:YES];
}

#pragma mark Gestures

- (void)handleTap {
    [self setExpanded:!_isExpanded animated:YES];
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)g {
    if (g.direction == UISwipeGestureRecognizerDirectionDown) {
        [self setExpanded:NO animated:YES];
        return;
    }
    if (_items.count < 2) return;
    NSInteger d = (g.direction == UISwipeGestureRecognizerDirectionLeft) ? 1 : -1;
    _index = (_index + d + (NSInteger)_items.count) % (NSInteger)_items.count;
    NBItem *it = [self currentItem];
    [UIView transitionWithView:_blur.contentView duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [self->_collapsed configure:it];
        [self->_expanded configure:it];
    } completion:nil];
    [self relayoutAnimated:YES];
    if ([NBSettings shared].haptics) [_haptic impactOccurred];
    [self scheduleIdleCollapse];
}

@end
