#import <Cocoa/Cocoa.h>
@class   WebPortalServer;

@interface AppDelegate : NSObject
{
    WebPortalServer *server;
    
    NSInteger poolSize;
    
    NSMutableArray *runLoops, *httpThreads;
    NSMutableArray<NSDictionary*> *runLoopsLoad;
    NSThread *serverThread;
}
@property(readonly) NSMutableArray *runLoops, *httpThreads;
@property(readonly) NSMutableArray<NSDictionary*> *runLoopsLoad;
@property NSInteger poolSize;
@end
