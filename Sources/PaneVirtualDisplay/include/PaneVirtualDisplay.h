// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 lemonadesaltbagel

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A virtual display: macOS treats it as a real one (its own Space, menu bar and arrangement) until it's released or
/// this process ends. Tests use it in place of a second monitor. Built on CoreGraphics' private CGVirtualDisplay
/// classes, which screen-sharing tools use.
@interface PaneVirtualDisplay : NSObject
/// `width` × `height` in points; `hiDPI` doubles the pixels. Nil when the private classes aren't there.
- (nullable instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height hiDPI:(BOOL)hiDPI name:(NSString *)name;
@property (readonly) CGDirectDisplayID displayID;
/// Removes the display now (also on dealloc).
- (void)remove;
@end

NS_ASSUME_NONNULL_END
