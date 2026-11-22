#import "NBRootListController.h"

@implementation NBRootListController

// One controller class serves every page; the link cells pass the plist name in "plistName".
- (NSArray *)specifiers {
    if (!_specifiers) {
        NSString *name = [self.specifier propertyForKey:@"plistName"] ?: @"Root";
        _specifiers = [self loadSpecifiersFromPlistName:name target:self];
    }
    return _specifiers;
}

@end
