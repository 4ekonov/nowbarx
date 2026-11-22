#import <UIKit/UIKit.h>
#import "NBDataSource.h"

// Permanent "ambient" cards: flashlight, hotspot, low power, VPN, charging, weather, screen time.
// They are shown one at a time (the most relevant) and only when the card stack is empty.
@interface NBAmbient : NSObject
+ (instancetype)shared;
- (NBItem *)currentItem;                       // nil when nothing is relevant / disabled
- (BOOL)isTorchOn;
- (void)setTorchOn:(BOOL)on;
- (void)setLockScreenVisible:(BOOL)visible;    // also drives the screen-time counter
@end
