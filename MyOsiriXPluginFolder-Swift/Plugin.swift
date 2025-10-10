import Foundation

class YOURPLUGINCLASS: PluginFilter {
    @IBOutlet var myWindow: NSWindow!
    
    override func filterImage(_ menuName: String!) -> Int {
        
        if( menuName == "Settings") {
            NSApp.beginSheet( myWindow, modalFor: BrowserController.currentBrowser().window!, modalDelegate: nil, didEnd: nil, contextInfo: nil)
        }
        
        return 0 // no error
    }
    
    @IBAction func okButton(_ sender: Any) {
        myWindow.close()
    }
    
    override func initPlugin() {
        let bundle = Bundle.init( identifier: "com.rossetantoine.OsiriXTestPlugin")
        bundle?.loadNibNamed( "Settings", owner: self, topLevelObjects:  nil)
        NSLog( "Hello from my plugin. This function is executed when OsiriX launches.")
    }
}
