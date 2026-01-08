#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

@interface WebArchiveExtractor : NSObject 
{
	WebResource *  m_mainResource;
	NSMutableSet * m_resources;
	
	//in m_resourceLookupTable HTML resource can be stored with relative or 
	//absolute path m_resourceLookupTable contains several keys for each resource 
	// (as least 2: absolute and relative paths)
	NSMutableDictionary * m_resourceLookupTable;
	
	/** the index file name */
	NSString * entryFileName;
	/** what kind of file to create (XML, XHTML, etc) */
	NSXMLDocumentContentKind contentKind;
	/** URL to add to the begining of the hrefs / srcs */
	NSString * URLPrepend;
}

@property (retain) WebResource *  m_mainResource;
@property (retain) NSMutableSet * m_resources;
@property (retain) NSMutableDictionary * m_resourceLookupTable;
@property (retain) NSString * entryFileName;
@property (retain) NSString * URLPrepend;
@property NSXMLDocumentContentKind contentKind;

+ (id) extractorWithArchive: (WebArchive *) archiveToParse;

/**
 * load web archive file
 */
- (void) loadWebArchive:(NSString*) pathToWebArchive;

/**
parse WebArchive (can be main archive, or subframeArchives)
added by Robert Covington to handle archives with subframeArchives
*/
-(void) parseWebArchive:(WebArchive *) archiveToParse; 

/**
 * add resource to resource table
 */
- (void) addResource:(WebResource *) resource;

/**
 * extract to directory
 */
- (NSString*) extractResources:(NSString*) path;

/**
 * private method
 * extract resource to existing packagePath (using outputResource)
 * (packagePath the same as path of extractResources message)
 */
- (void) extractResource:(WebResource *) resource packagePath: (NSString*) path;

/**
 * protected method
 * write resource data to filePath
 * Parent directory of filePath should exists
 */
-(void) outputResource:(WebResource *) resource filePath: (NSString*) filePath packagePath: (NSString*) packagePath;

- (void) setEntryFileName:(NSString *) filename;
- (NSString *) entryFileName;

- (void) setContentKind:(NSXMLDocumentContentKind) kind;
- (NSXMLDocumentContentKind) contentKind;

- (void) setURLPrepend:(NSString *) url;
- (NSString *) URLPrepend;

@end
