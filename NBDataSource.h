#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NBItemType) {
    NBItemTypeMedia,
    NBItemTypeTimer,
    NBItemTypeAlarm
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
@end

extern NSString *const NBItemsChangedNotification;

@interface NBDataSource : NSObject
@property (nonatomic, readonly) NSArray<NBItem *> *items;
+ (instancetype)shared;
- (void)start;
- (BOOL)hasMedia;
- (void)setPolling:(BOOL)on;
- (void)mediaCommand:(int)command;
- (void)toggleTimer:(NBItem *)item;
- (void)stopTimer:(NBItem *)item;
@end
