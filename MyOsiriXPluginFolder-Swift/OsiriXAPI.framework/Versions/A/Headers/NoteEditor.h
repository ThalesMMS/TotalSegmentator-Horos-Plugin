/*=========================================================================
 Program:   OsiriX
 Copyright (c) 2010 - 2025 Pixmeo SARL
 266 rue de Bernex
 CH-1233 Bernex
 Switzerland
 All rights reserved.
 =========================================================================*/

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class DicomStudy;

@interface NoteEditor : NSWindowController <NSWindowDelegate> {
    IBOutlet NSTextView *textView;
}
@property (retain, nullable, nonatomic) DicomStudy *study;

+(NoteEditor*) showEditorForStudy:(DicomStudy*) study;

@end

NS_ASSUME_NONNULL_END
