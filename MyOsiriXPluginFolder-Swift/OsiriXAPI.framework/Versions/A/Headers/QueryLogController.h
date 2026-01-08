/*=========================================================================
 Program:   OsiriX
 Copyright (c) 2010 - 2025 Pixmeo SARL
 266 rue de Bernex
 CH-1233 Bernex
 Switzerland
 All rights reserved.
 =========================================================================*/

#import <Cocoa/Cocoa.h>

/** \brief Array Controlle for query logs */
@interface QueryLogController : NSArrayController {
    
}
@property (retain) NSPredicate *defaultPredicate;
@property (retain) NSFetchRequest *lastRequest;
@property NSUInteger countFetch;
@end
