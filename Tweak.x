#import <UIKit/UIKit.h>
#import "NBBarView.h"
#import "NBDataSource.h"
#import "NBSettings.h"

@interface CSCoverSheetViewController : UIViewController
@end

static NBBarView *gBar;

static void NBEnsureBar(UIViewController *vc) {
    UIView *host = vc.view;
    if (!host) return;
    if (!gBar) gBar = [[NBBarView alloc] initWithFrame:host.bounds];
    if (gBar.superview != host) {
        gBar.frame = host.bounds;
        [host addSubview:gBar];
    } else {
        [host bringSubviewToFront:gBar];
    }
}

%hook CSCoverSheetViewController

- (void)viewDidLoad {
    %orig;
    NBEnsureBar(self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NBEnsureBar(self);
    [gBar setActive:YES];
}

- (void)viewDidLayoutSubviews {
    %orig;
    NBEnsureBar(self);
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [gBar setActive:NO];
}

%end

%ctor {
    @autoreleasepool {
        [NBSettings shared];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NBDataSource shared] start];
        });
    }
}
