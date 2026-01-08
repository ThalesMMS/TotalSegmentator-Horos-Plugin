/*=========================================================================
 Program:   OsiriX
 Copyright (c) 2010 - 2025 Pixmeo SARL
 266 rue de Bernex
 CH-1233 Bernex
 Switzerland
 All rights reserved.
 =========================================================================*/

//Abstract class for generalized control of DICOM sending.

#import <Cocoa/Cocoa.h>
#import "DicomDatabase.h"

enum TransferSyntaxCodes
{
    SendEmptyTransferSyntax = -5,
    SendUnspecifiedTransferSyntax = -4,
    SendWithWildcardTransferSyntax = -3,
    SendWithPreserveTransferSyntax = -2,
    SendWithOriginalTransferSyntax = -1,
	SendExplicitLittleEndian = 0, 
	SendJPEG2000Lossless = 1, 
	SendJPEG2000Lossy10 = 2,  
	SendJPEG2000Lossy20 = 3, 
	SendJPEG2000Lossy50 = 4, 
	SendJPEGLossless = 5,  
	SendJPEGLossy9 = 6, 
	SendJPEGLossy8 = 7, 
	SendJPEGLossy7 = 8, 
	SendImplicitLittleEndian = 9, 
	SendRLE = 10, 
	SendExplicitBigEndian = 11, 
	SendBZip = 12,
    SendJPEGLSLossless = 13, 
	SendJPEGLSLossy10 = 14,  
	SendJPEGLSLossy20 = 15, 
	SendJPEGLSLossy50 = 16,
    SendLittleEndianOctetStream = 17,
    SendJPEGXLLossless = 18,
    SendJPEGXLLossy10 = 19,
    SendJPEGXLLossy20 = 20,
    SendJPEGXLLossy50 = 21,
};
typedef enum TransferSyntaxCodes TransferSyntaxCodes;

enum SendServerType { osirixServer, offisServer };

@class Wait;
@class DCMTKStoreSCU;

/** \brief Window Controller for DICOM Send */
@interface SendController : NSWindowController <NSMenuDelegate>
{
	NSArray				*_files;
	NSInteger			_keyImageIndex;
	NSUInteger			_serverIndex;
	NSInteger			_offisTS;
	BOOL				_readyForRelease;
	BOOL				_abort;
    BOOL                doNotUpdatePreferences;
	
	IBOutlet NSPopUpButton	*newServerList;
	IBOutlet NSMatrix		*keyImageMatrix;
	IBOutlet NSTextField	*numberImagesTextField, *addressAndPort;
	IBOutlet NSPopUpButton	*syntaxListOffis;
    
    IBOutlet NSWindow       *multipleDestinationsWindow;
    IBOutlet NSArrayController *multipleDestinationsArrayController;
    NSArray *destinationsArray;
}
@property(retain, nonatomic) NSArray *destinationsArray;

+ (void) sendFiles:(NSArray *)files;
+ (void) sendFiles:(NSArray *)files toNode: (NSDictionary*) node;
+ (void) sendFiles:(NSArray *)files toNode: (NSDictionary*) node usingSyntax: (int) syntax;

+ (BOOL) executeSend:(NSArray*) images database: (DicomDatabase*) db showError: (BOOL) showError server:(NSDictionary*) server error:(NSError**) returnedError;
+ (BOOL) executeSend:(NSArray*) images database: (DicomDatabase*) db showError: (BOOL) showError server:(NSDictionary*) server error:(NSError**) returnedError syntax: (int) syntax;

+ (NSArray*) changeTransferSyntaxTo: (int) newSyntax quality: (int) opt_Quality forFiles: (NSArray*) filesToSend tmpFiles:(NSArray**) tmpFiles;
+ (NSArray*) changeTransferSyntaxToAnyOfTheseSyntaxes: (NSArray*) newSyntaxes quality: (int) opt_Quality forFiles: (NSArray*) filesToSend tmpFiles:(NSArray**) tmpFiles;
+ (int) sendControllerObjects;
- (id)initWithFiles:(NSArray *)files;
- (id)server;
- (IBAction) endSelectServer:(id) sender;
- (int)keyImageIndex;
- (void)setKeyImageIndex:(int)index;
- (IBAction)selectServer: (id)sender;
- (void) updateDestinationPopup:(NSNotification*) note;

@end
