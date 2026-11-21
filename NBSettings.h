#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

extern NSString *const NBSettingsChangedNotification;

@interface NBSettings : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL showMedia;
@property (nonatomic, readonly) BOOL showTimer;
@property (nonatomic, readonly) BOOL showAlarm;
@property (nonatomic, readonly) BOOL spotifyOnly;
@property (nonatomic, readonly) BOOL haptics;
@property (nonatomic, readonly) CGFloat bottomOffset;
@property (nonatomic, readonly) CGFloat xOffset;
@property (nonatomic, readonly) CGFloat scale;
+ (instancetype)shared;
@end
