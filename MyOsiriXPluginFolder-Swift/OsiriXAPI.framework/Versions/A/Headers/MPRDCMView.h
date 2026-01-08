/*=========================================================================
 Program:   OsiriX
 Copyright (c) 2010 - 2025 Pixmeo SARL
 266 rue de Bernex
 CH-1233 Bernex
 Switzerland
 All rights reserved.
 =========================================================================*/

#import <Cocoa/Cocoa.h>

#import "DCMView.h"
#import "VRController.h"
#import "MPRController.h"
#import "N3Geometry.h"

@class OSIROIManager;

@interface MPRDCMView : DCMView
{
	int viewID, mouseDownTool;
	VRView *vrView;
	DCMPix *pix;
	Camera *camera;
	float angleMPR;
	BOOL dontUseAutoLOD;
	OSIROIManager *_ROIManager;

	float crossLinesA[2][3];
	float crossLinesB[2][3];
	
	int viewExport;
	float fromIntervalExport, toIntervalExport;
	float LOD, previousResolution, previousPixelSpacing, previousOrientation[ 9], previousOrigin[ 3];
	
    int dragLineNumber;
    NSPoint dragLineVector;
	BOOL rotateLines;
	BOOL moveCenter;
	BOOL displayCrossLines, restoreDisplayCrossLinesAfterScroll;
	BOOL lastRenderingWasMoveCenter;
	
	float rotateLinesStartAngle;
	
	BOOL dontReenterCrossReferenceLines;
	
	BOOL dontCheckRoiChange;
    
    ROI *edited2DPointROI;
    NSRect edited2DPointROIPosition;
}

@property (readonly) DCMPix *pix;
@property (retain) Camera *camera;
@property (retain) ROI *edited2DPointROI;
@property float angleMPR, fromIntervalExport, toIntervalExport, LOD;
@property int viewExport, dragLineNumber;
@property (nonatomic) BOOL displayCrossLines, dontUseAutoLOD;
@property (readonly) VRView *vrView;
@property (readonly) BOOL rotateLines, moveCenter;
@property BOOL restoreDisplayCrossLinesAfterScroll;

- (BOOL)is2DTool:(short)tool;
- (void) setDCMPixList:(NSMutableArray*)pix filesList:(NSArray*)files roiList:(NSMutableArray*)rois firstImage:(short)firstImage type:(char)type reset:(BOOL)reset;
- (void) setVRView: (VRView*) v viewID:(int) i;
- (void) updateViewMPR;
- (void) updateViewMPR:(BOOL) computeCrossReferenceLines;
- (void) updateViewMPR:(BOOL) computeCrossReferenceLines checkForFrame: (BOOL) checkForFrame;
- (void) setCrossReferenceLines: (float[2][3]) a and: (float[2][3]) b;
- (void) saveCamera;
- (void) restoreCamera;
- (void) restoreCameraAndCheckForFrame: (BOOL) v;
- (void) restoreCameraAndCheckForFrame: (BOOL) v restoreScale: (BOOL) s;
- (void) updateMousePosition: (NSEvent*) theEvent;
- (void) detect2DPointInThisSlice;
- (void) magicTrick;
- (void) removeROI: (NSNotification*) note;

- (N3AffineTransform)pixToDicomTransform; // converts points in the DCMPix's coordinate space ("Slice Coordinates") into the DICOM space (patient space with mm units)

- (NSColor*)borderColor;

@end
