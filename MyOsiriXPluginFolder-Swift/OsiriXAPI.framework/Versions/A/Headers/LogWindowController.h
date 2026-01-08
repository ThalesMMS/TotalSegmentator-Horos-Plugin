/*=========================================================================
 Program:   OsiriX
 Copyright (c) 2010 - 2025 Pixmeo SARL
 266 rue de Bernex
 CH-1233 Bernex
 Switzerland
 All rights reserved.
 =========================================================================*/



#import <Cocoa/Cocoa.h>

@class QueryLogController;

/** \brief  Window Controller for network logs */
@interface LogWindowController : NSWindowController <NSTableViewDelegate, NSWindowDelegate, NSMenuDelegate>
{
	IBOutlet QueryLogController *receive, *move, *send, *web, *display;
    IBOutlet NSTableView *receiveTableView, *moveTableView, *sendTableView, *webTableView, *displayTableView;
    IBOutlet NSSearchField *receiveSearch, *moveSearch, *sendSearch, *webSearch, *displaySearch;
}

@property NSUInteger countFetch;

- (IBAction) export:(id) sender;

@end
