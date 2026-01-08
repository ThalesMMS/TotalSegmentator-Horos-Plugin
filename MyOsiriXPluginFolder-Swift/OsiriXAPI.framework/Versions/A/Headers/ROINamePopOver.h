//
//  ROINamePopOver.h
//  OsiriX
//
//  Created by Antoine Rosset on 28.06.2024.
//  Copyright © 2024 OsiriX Team. All rights reserved.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class DCMView, ROI;

@interface ROINamePopOver : NSViewController <NSPopoverDelegate, NSWindowDelegate, NSTextFieldDelegate>

@property (nonatomic) float textSize;
@property NSRect rect;
@property (retain, nullable, nonatomic) NSString *name;
@property (retain, nullable) NSPopover *popover;
@property (retain, nullable) id delegate;
@property (retain, nullable) ROI *roi;
@property (retain, nullable) NSWindowController *senderWindowController;
@property (retain, nullable) id senderFirstResponder;
@property NSTimeInterval openedTime;

+ (id) showROINamePopOverForROI:(ROI*) roi controller: (NSWindowController*) controller;
- (void) makeFirstResponder;
@end

NS_ASSUME_NONNULL_END
