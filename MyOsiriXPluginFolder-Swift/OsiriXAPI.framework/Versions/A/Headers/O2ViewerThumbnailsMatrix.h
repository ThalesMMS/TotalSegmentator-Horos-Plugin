/*=========================================================================
 Program:   OsiriX
 Copyright (c) 2010 - 2025 Pixmeo SARL
 266 rue de Bernex
 CH-1233 Bernex
 Switzerland
 All rights reserved.
 =========================================================================*/

#import <Cocoa/Cocoa.h>

@interface O2ViewerThumbnailsMatrix : NSMatrix {
    NSPoint draggingStartingPoint;
    NSTimeInterval doubleClick;
    NSCell *doubleClickCell;
    BOOL recomputeCells;
    NSRect *rectsCache;
    NSScreen *screen;
}

- (void) resetCacheCells;
+ (BOOL)draggingThumbnailCell;
@end

@interface O2ViewerThumbnailsMatrixRepresentedObject : NSObject {
    id _object;
    NSArray* _children;
    int curStudyIndexAll;
    int numberOfImages;
}

@property(retain) id object;
@property(retain) NSArray* children;
@property(retain) NSScreen *screen;
@property int curStudyIndexAll, numberOfImages;
@property BOOL isOpenedStudy;

+ (id)object:(id)object children:(NSArray*)children studyIndex: (int) sI numberOfImages: (int) nI screen:(NSScreen*) screen;

@end
