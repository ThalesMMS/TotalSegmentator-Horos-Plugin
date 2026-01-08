//
//  screenCapture.h
//  OsiriX
//
//  Created by Antoine Rosset on 21.05.23.
//  Copyright © 2023 OsiriX Team. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class DCMView;

@interface ScreenCapture : NSViewController <NSPopoverDelegate>

@property BOOL RGB, resize, cancel, saveOnDesktop, asDraggedFile, saveAsFile, saveInFolder, copyToClipboard, exportAsDICOM, openWithPreview;
@property int resizeDimension;
@property(nonatomic) int resizeValue;
@property (retain, nullable, nonatomic) NSNumber *seriesNumber;
@property NSRect rect;
@property (retain, nullable) NSString *seriesName, *imageSize;
@property (retain, nullable) NSPopover *popover;
@property (retain, nullable) id delegate;

+ (id) showScreenCaptureForRect: (NSRect) rect inView: (NSView*) view;
- (IBAction)copyToClipboard:(nullable NSButton*)sender;
- (void)performCopyToClipboardClick;
- (void)performDefaultAction;
@end

NS_ASSUME_NONNULL_END
