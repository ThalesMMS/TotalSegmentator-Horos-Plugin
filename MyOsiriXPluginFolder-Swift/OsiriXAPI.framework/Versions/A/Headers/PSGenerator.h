/* PSGenerator */

#import <Cocoa/Cocoa.h>

@interface PSGenerator : NSObject
{
    NSString *sourceString;
	unsigned minLength, maxLength;
}
@property (retain) NSString *sourceString;

- (id) initWithSourceString: (NSString *) str
				  minLength: (unsigned) min
				  maxLength: (unsigned) max;

- (NSString *) generate;
@end
