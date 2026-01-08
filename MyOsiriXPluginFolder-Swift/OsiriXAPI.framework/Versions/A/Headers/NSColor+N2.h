/*=========================================================================
 Program:   OsiriX
 Copyright (c) 2010 - 2025 Pixmeo SARL
 266 rue de Bernex
 CH-1233 Bernex
 Switzerland
 All rights reserved.
 =========================================================================*/

#import <Cocoa/Cocoa.h>


@interface NSColor (N2)

-(BOOL)isEqualToColor:(NSColor*)color;
-(BOOL)isEqualToColor:(NSColor*)color alphaThreshold:(CGFloat)alphaThreshold;
-(NSString*) hexadecimalValue;
-(NSString*) rgbaCSSValue;
-(NSColor*) inverted;
-(NSColor*) oppsite;
@end
