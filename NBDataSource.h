#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NBItemType) {
    NBItemTypeMedia,
    NBItemTypeTimer,
    NBItemTypeAlarm,
    NBItemTypeStopwatch,
    NBItemTypeStatus   // permanent "ambient" card (flashlight, hotspot, weather...), never part of the stack
};

@interface NBItem : NSObject
@property (nonatomic) NBItemType type;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, strong) UIImage *artwork;
@property (nonatomic, strong) UIColor *tint;
@property (nonatomic) BOOL playing;
@property (nonatomic) BOOL paused;
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSTimeInterval elapsed;
@property (nonatomic) double rate;
@property (nonatomic, strong) NSDate *refDate;
@property (nonatomic) NSTimeInterval remaining;
@property (nonatomic, strong) id underlying;
// status cards
@property (nonatomic, copy) NSString *symbol;        // SF Symbol shown in the round icon
@property (nonatomic, strong) UIColor *accent;       // icon colour
@property (nonatomic, copy) NSString *actionSymbol;  // SF Symbol of the trailing button (optional)
@property (nonatomic, copy) void (^action)(void);    // what the trailing button does
@end

extern NSString *const NBItemsChangedNotification;

@interface NBDataSource : NSObject
@property (nonatomic, readonly) NSArray<NBItem *> *items;
+ (instancetype)shared;
- (void)start;
- (BOOL)hasMedia;
- (void)setPolling:(BOOL)on;
- (void)ambientChanged;   // called by NBAmbient when something it shows has changed
- (void)mediaCommand:(int)command;
- (void)toggleTimer:(NBItem *)item;
- (void)stopTimer:(NBItem *)item;
@end
