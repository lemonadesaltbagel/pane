// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

#import "PaneVirtualDisplay.h"

// CoreGraphics' private classes, declared here only as far as they're used.
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

@implementation PaneVirtualDisplay {
    id _display;
}

- (nullable instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height hiDPI:(BOOL)hiDPI name:(NSString *)name {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor"), displayClass = NSClassFromString(@"CGVirtualDisplay"),
          settingsClass = NSClassFromString(@"CGVirtualDisplaySettings"), modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) return nil;
    if (!(self = [super init])) return nil;
    unsigned int scale = hiDPI ? 2 : 1;
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.maxPixelsWide = width * scale;
    descriptor.maxPixelsHigh = height * scale;
    descriptor.sizeInMillimeters = CGSizeMake(width * 0.27, height * 0.27); // about 94 dpi at 1×
    descriptor.vendorID = 0x7061; // "pa"
    descriptor.productID = 0x6e65; // "ne"
    descriptor.serialNum = (unsigned int)arc4random();
    descriptor.terminationHandler = ^(id a, id b) {};
    CGVirtualDisplay *display = [[displayClass alloc] initWithDescriptor:descriptor];
    if (!display || display.displayID == 0) return nil;
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[modeClass alloc] initWithWidth:width * scale height:height * scale refreshRate:60]];
    if (![display applySettings:settings]) return nil;
    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display ? ((CGVirtualDisplay *)_display).displayID : 0;
}

- (void)remove {
    _display = nil;
}

@end
