#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 A minimal DCMObject declaration used for Swift bridging when the full DICOM
 headers are not available in the build environment. Horos supplies the real
 implementation at runtime.
 */
@interface DCMObject : NSObject

- (nullable instancetype)initWithContentsOfFile:(NSString *)file
                              decodingPixelData:(BOOL)decodingPixelData NS_DESIGNATED_INITIALIZER;

+ (nullable instancetype)objectWithContentsOfFile:(NSString *)file
                               decodingPixelData:(BOOL)decodePixelData;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
