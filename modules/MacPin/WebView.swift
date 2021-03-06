/// MacPin WKWebView subclass
///
/// Add some porcelain to WKWebViews


import WebKit
import WebKitPrivates
import JavaScriptCore
import UTIKit

@objc protocol WebViewScriptExports: JSExport { // $.WebView & $.browser.tabs[WebView]
	init?(object: [String:AnyObject]) //> new WebView({url: 'http://example.com'});
	// can only JSExport one init*() func!
	// https://github.com/WebKit/webkit/blob/master/Source/JavaScriptCore/API/tests/testapi.mm
	// https://github.com/WebKit/webkit/blob/master/Source/JavaScriptCore/API/JSWrapperMap.mm#L412

	var title: String? { get }
	var url: String { get set }
	var transparent: Bool { get set }
	var userAgent: String { get set }
	var allowsMagnification: Bool { get set }
	//var canGoBack: Bool { get }
	//var canGoForward: Bool { get }
	//var hasOnlySecureContent: Bool { get }
	// var userLabel // allow to be initiated with a trackable tag
	var injected: [String] { get }
	static var MatchedAddressOptions: [String:String] { get set }
	func close()
	@objc(evalJS::) func evalJS(js: String, callback: JSValue?)
	@objc(asyncEvalJS:::) func asyncEvalJS(js: String, delay: Double, callback: JSValue?)
	func loadURL(urlstr: String) -> Bool
	func loadIcon(icon: String) -> Bool
	func preinject(script: String) -> Bool
	func postinject(script: String) -> Bool
	func addHandler(handler: String) // FIXME kill
	func subscribeTo(handler: String)
	//func goBack()
	//func goForward()
	//func reload()
	//func reloadFromOrigin()
	//func stopLoading() -> WKNavigation?
}

@objc class MPWebView: WKWebView, WebViewScriptExports {
	static var MatchedAddressOptions: [String:String] = [:] // cvar singleton

	static func WebProcessConfiguration() -> _WKProcessPoolConfiguration {
		let config = _WKProcessPoolConfiguration()
		//config.injectedBundleURL = NSbundle.mainBundle().URLForAuxillaryExecutable("contentfilter.wkbundle")
		// https://github.com/WebKit/webkit/blob/master/Source/WebKit2/WebProcess/InjectedBundle/API/c/WKBundle.cpp
		return config
	}
	static var sharedWebProcessPool = WKProcessPool()._initWithConfiguration(MPWebView.WebProcessConfiguration()) // cvar singleton

	var injected: [String] = [] //list of script-names already loaded

	var jsdelegate = AppScriptRuntime.shared.jsdelegate

	var url: String { // accessor for JSC, which doesn't support `new URL()`
		get { return URL?.absoluteString ?? "" }
		set { loadURL(newValue) }
	}

	var userAgent: String {
		get { return _customUserAgent ?? _userAgent ?? "" }
		// https://github.com/WebKit/webkit/blob/master/Source/WebCore/page/mac/UserAgentMac.mm#L48
		set(agent) { if !agent.isEmpty { _customUserAgent = agent } }
	}

	var topFrame: WKView? {
		get {
			guard let wkview = subviews.first as? WKView else { return nil }
			return wkview
		}
	}

#if os(OSX)
	var transparent: Bool {
		get { return _drawsTransparentBackground }
		set(transparent) {
			_drawsTransparentBackground = transparent
			//^ background-color:transparent sites immediately bleedthru to a black CALayer, which won't go clear until the content is reflowed or reloaded
 			// so frobble frame size to make content reflow & re-colorize
			setFrameSize(NSSize(width: frame.size.width, height: frame.size.height - 1)) //needed to fully redraw w/ dom-reflow or reload!
			evalJS("window.dispatchEvent(new window.CustomEvent('MacPinWebViewChanged',{'detail':{'transparent': \(transparent)}}));" +
				"document.head.appendChild(document.createElement('style')).remove();") //force redraw in case event didn't
				//"window.scrollTo();")
			setFrameSize(NSSize(width: frame.size.width, height: frame.size.height + 1))
			needsDisplay = true
		}
	}
#elseif os(iOS)
	var transparent = false // no overlaying MacPin apps upon other apps in iOS, so make it a no-op
	var allowsMagnification = true // not exposed on iOS WebKit, make it no-op
#endif

	let favicon: FavIcon = FavIcon()

	convenience init(config: WKWebViewConfiguration? = nil, agent: String? = nil, isolated: Bool? = false, privacy: Bool? = false) {
		// init webview with custom config, needed for JS:window.open() which links new child Windows to parent Window
		let configuration = config ?? WKWebViewConfiguration() // NSURLSessionConfiguration ? https://www.objc.io/issues/5-ios7/from-nsurlconnection-to-nsurlsession/
		let prefs = WKPreferences() // http://trac.webkit.org/browser/trunk/Source/WebKit2/UIProcess/API/Cocoa/WKPreferences.mm
#if os(OSX)
		prefs.plugInsEnabled = true // NPAPI for Flash, Java, Hangouts
		prefs._developerExtrasEnabled = true // Enable "Inspect Element" in context menu
#endif
		if let privacy = privacy where privacy {
			//prevent HTML5 application cache and asset/page caching by WebKit, MacPin never saves any history itself
			prefs._storageBlockingPolicy = .BlockAll
		}
		prefs._allowFileAccessFromFileURLs = true // file://s can xHr other file://s
		//prefs._isStandalone = true // `window.navigator.standalone == true` mimicing MobileSafari's springboard-link shell mode
		//prefs.minimumFontSize = 14 //for blindies
		prefs.javaScriptCanOpenWindowsAutomatically = true;
#if WK2LOG
		prefs._diagnosticLoggingEnabled = true
		prefs._logsPageMessagesToSystemConsoleEnabled = true // dumps to ASL
		//prefs._javaScriptRuntimeFlags = 0 // ??
#endif
		configuration.preferences = prefs
		configuration.suppressesIncrementalRendering = false
		//if let privacy = privacy { if privacy { configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore() } }
		if let isolated = isolated {
			if isolated {
				configuration.processPool = WKProcessPool() // not "private" but usually gets new session variables from server-side webapps
			} else {
				configuration.processPool = config?.processPool ?? MPWebView.self.sharedWebProcessPool
			}
		}
		self.init(frame: CGRectZero, configuration: configuration)
#if SAFARIDBG
		_allowsRemoteInspection = true // start webinspectord child
		// enables Safari.app->Develop-><computer name> remote debugging of JSCore and all webviews' JS threads
		// http://stackoverflow.com/questions/11361822/debug-ios-67-mobile-safari-using-the-chrome-devtools
#endif
		//_editable = true // https://github.com/WebKit/webkit/tree/master/Tools/WebEditingTester

		allowsBackForwardNavigationGestures = true
		allowsLinkPreview = true // enable Force Touch peeking (when not captured by JS/DOM)
#if os(OSX)
		allowsMagnification = true
		_applicationNameForUserAgent = "Version/8.0.5 Safari/600.5.17"
#elseif os(iOS)
		_applicationNameForUserAgent = "Version/8.0 Mobile/12F70 Safari/600.1.4"
#endif
		if let agent = agent { if !agent.isEmpty { _customUserAgent = agent } }
	}

	convenience required init?(object: [String:AnyObject]) {
		// check for isolated pre-init
		if let isolated = object["isolated"] as? Bool {
			self.init(config: nil, isolated: isolated)
		} else if let privacy = object["private"] as? Bool {
			// a private tab would imply isolation, not sweating lack of isolated+private corner case
			self.init(config: nil, privacy: privacy)
		} else {
			self.init(config: nil)
		}
		var url = NSURL(string: "about:blank")
		for (key, value) in object {
			switch value {
				case let urlstr as String where key == "url": url = NSURL(string: urlstr)
				case let agent as String where key == "agent": _customUserAgent = agent
				case let icon as String where key == "icon": loadIcon(icon)
				case let magnification as Bool where key == "allowsMagnification": allowsMagnification = magnification
				case let transparent as Bool where key == "transparent":
#if os(OSX)
					_drawsTransparentBackground = transparent
#endif
				case let value as [String] where key == "preinject": for script in value { preinject(script) }
				case let value as [String] where key == "postinject": for script in value { postinject(script) }
				case let value as [String] where key == "handlers": for handler in value { addHandler(handler) } //FIXME kill
				case let value as [String] where key == "subscribeTo": for handler in value { subscribeTo(handler) }
				default: warn("unhandled param: `\(key): \(value)`")
			}
		}

		if let url = url { gotoURL(url) } else { return nil }
	}

	convenience required init(url: NSURL, agent: String? = nil, isolated: Bool? = false, privacy: Bool? = false) {
		self.init(config: nil, agent: agent, isolated: isolated, privacy: privacy)
		gotoURL(url)
	}

	override var description: String { return "<\(self.dynamicType)> `\(title ?? String())` [\(URL ?? String())]" }
	deinit { warn(description) }

	@objc(evalJS::) func evalJS(js: String, callback: JSValue? = nil) {
		if let callback = callback where callback.isObject { //is a function or a {}
			warn("callback: \(callback)")
			evaluateJavaScript(js, completionHandler:{ (result: AnyObject?, exception: NSError?) -> Void in
				// (result: WebKit::WebSerializedScriptValue*, exception: WebKit::CallbackBase::Error)
				//withCallback.callWithArguments([result, exception]) // crashes, need to translate exception into something javascripty
				warn("callback() ~> \(result),\(exception)")
				// FIXME: check if exception is WKErrorCode.JavaScriptExceptionOccurred,.JavaScriptResultTypeIsUnsupported
				if let result = result {
					callback.callWithArguments([result, true]) // unowning withCallback causes a crash and weaking it muffs the call
				} else {
					// passing nil crashes
					callback.callWithArguments([JSValue(nullInContext: callback.context), true])
				}
				return
			})
			return
		}
		evaluateJavaScript(js, completionHandler: nil)
	}

	// cuz JSC doesn't come with setTimeout()
	@objc(asyncEvalJS:::) func asyncEvalJS(js: String, delay: Double, callback: JSValue?) {
		let backgroundQueue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0)
		let delayTime = dispatch_time(DISPATCH_TIME_NOW, Int64(Double(NSEC_PER_SEC) * delay))
		dispatch_after(delayTime, backgroundQueue) {
			if let callback = callback where callback.isObject { //is a function or a {}
				warn("callback: \(callback)")
				self.evaluateJavaScript(js, completionHandler:{ (result: AnyObject?, exception: NSError?) -> Void in
					// (result: WebKit::WebSerializedScriptValue*, exception: WebKit::CallbackBase::Error)
					//withCallback.callWithArguments([result, exception]) // crashes, need to translate exception into something javascripty
					warn("callback() ~> \(result),\(exception)")
					if let result = result {
						callback.callWithArguments([result, true]) // unowning withCallback causes a crash and weaking it muffs the call
					} else {
						// passing nil crashes
						callback.callWithArguments([JSValue(nullInContext: callback.context), true])
					}
				})
			} else {
				self.evaluateJavaScript(js, completionHandler: nil)
			}
		}
	}

	func close() { removeFromSuperview() } // signal VC too?

	func gotoURL(url: NSURL) {
		guard #available(OSX 10.11, iOS 9.1, *) else { loadRequest(NSURLRequest(URL: url)); return }
		guard url.scheme == "file" else { loadRequest(NSURLRequest(URL: url)); return }
		if let readURL = url.URLByDeletingLastPathComponent {
		//if let readURL = url.baseURL {
		//if let readURL = url.URLByDeletingPathExtension {
			warn("Bypassing CORS: \(readURL)")
			loadFileURL(url, allowingReadAccessToURL: readURL)
		}
	}

	func loadURL(urlstr: String) -> Bool {
		if let url = NSURL(string: urlstr) {
			gotoURL(url as NSURL)
			return true
		}
		return false // tell JS we were given a malformed URL
	}

	func scrapeIcon() { // extract icon location from current webpage and initiate retrieval
		evaluateJavaScript("if (icon = document.head.querySelector('link[rel$=icon]')) { icon.href };", completionHandler:{ [unowned self] (result: AnyObject?, exception: NSError?) -> Void in
			if let href = result as? String { // got link for icon or apple-touch-icon from DOM
				self.loadIcon(href)
			} else if let url = self.URL, iconurlp = NSURLComponents(URL: url, resolvingAgainstBaseURL: false) where !((iconurlp.host ?? "").isEmpty) {
				iconurlp.path = "/favicon.ico" // request a root-of-domain favicon
				self.loadIcon(iconurlp.string!)
			}
		})
	}

	func loadIcon(icon: String) -> Bool {
		if let url = NSURL(string: icon) where !icon.isEmpty {
			favicon.url = url
			return true
		}
		return false
	}

	func preinject(script: String) -> Bool {
		//if contains(injected, script) { return true } //already loaded
		if !injected.contains(script) && loadUserScriptFromBundle(script, webctl: configuration.userContentController, inject: .AtDocumentStart, onlyForTop: false) { injected.append(script); return true }
		return false
	}
	func postinject(script: String) -> Bool {
		//if contains(injected, script) { return true } //already loaded
		if !injected.contains(script) && loadUserScriptFromBundle(script, webctl: configuration.userContentController, inject: .AtDocumentEnd, onlyForTop: false) { injected.append(script); return true }
		return false
	}
	func addHandler(handler: String) { configuration.userContentController.addScriptMessageHandler(AppScriptRuntime.shared, name: handler) } //FIXME kill
	func subscribeTo(handler: String) {
		configuration.userContentController.removeScriptMessageHandlerForName(handler)
		configuration.userContentController.addScriptMessageHandler(AppScriptRuntime.shared, name: handler)
	}

	func REPL() {
		termiosREPL({ (line: String) -> Void in
			self.evaluateJavaScript(line, completionHandler:{ (result: AnyObject?, exception: NSError?) -> Void in
				// FIXME: the JS execs async so these print()s don't consistently precede the REPL thread's prompt line
				if let result = result { Swift.print(result) }
				if let exception = exception { Swift.print("Error: \(exception)") }
			})
		},
		ps1: __FILE__,
		ps2: __FUNCTION__,
		abort: { () -> Void in
			// EOF'd by Ctrl-D
			// self.close() // FIXME: self is still retained (by the browser?)
		})
	}

#if os(OSX)

	// FIXME: unified save*()s like Safari does with a drop-down for "Page Source" & Web Archive, or auto-mime for single non-HTML asset
	func saveWebArchive() {
		_getWebArchiveDataWithCompletionHandler() { [unowned self] (data: NSData!, err: NSError!) -> Void in
			//pop open a save Panel to dump data into file
			let saveDialog = NSSavePanel();
			saveDialog.canCreateDirectories = true
			saveDialog.allowedFileTypes = [kUTTypeWebArchive as String]
			if let window = self.window {
				saveDialog.beginSheetModalForWindow(window) { (result: Int) -> Void in
					if let url = saveDialog.URL, path = url.path where result == NSFileHandlingPanelOKButton {
						NSFileManager.defaultManager().createFileAtPath(path, contents: data, attributes: nil)
						}
				}
			}
		}
	}

	func savePage() {
		_getMainResourceDataWithCompletionHandler() { [unowned self] (data: NSData!, err: NSError!) -> Void in
			//pop open a save Panel to dump data into file
			let saveDialog = NSSavePanel();
			saveDialog.canCreateDirectories = true
			if let mime = self._MIMEType, uti = UTI(MIMEType: mime) {
				saveDialog.allowedFileTypes = [uti.UTIString]
			}
			if let window = self.window {
				saveDialog.beginSheetModalForWindow(window) { (result: Int) -> Void in
					if let url = saveDialog.URL, path = url.path where result == NSFileHandlingPanelOKButton {
						NSFileManager.defaultManager().createFileAtPath(path, contents: data, attributes: nil)
						}
				}
			}
		}
	}

	override func validateUserInterfaceItem(anItem: NSValidatedUserInterfaceItem) -> Bool {
		switch (anItem.action().description) {
			//case "askToOpenCurrentURL": return true
			case "copyAsPDF": fallthrough
			case "console": fallthrough
			case "saveWebArchive": fallthrough
			case "savePage": return true
			//case "printWebView:": return true // _printOperation not avail in 10.11.2's WebKit
			default:
				warn(anItem.action().description)
				return super.validateUserInterfaceItem(anItem)
		}

	}

	/* overide func _registerForDraggedTypes() {
		// https://github.com/WebKit/webkit/blob/f72e25e3ba9d3d25d1c3a4276e8dffffa4fec4ae/Source/WebKit2/UIProcess/API/mac/WKView.mm#L3653
		self.registerForDraggedTypes([ // https://github.com/WebKit/webkit/blob/master/Source/WebKit2/Shared/mac/PasteboardTypes.mm [types]
			// < forEditing
			WebArchivePboardType, NSHTMLPboardType, NSFilenamesPboardType, NSTIFFPboardType, NSPDFPboardType,
		    NSURLPboardType, NSRTFDPboardType, NSRTFPboardType, NSStringPboardType, NSColorPboardType, kUTTypePNG,
			// < forURL
			WebURLsWithTitlesPboardType, //webkit proprietary
			NSURLPboardType, // single url from older apps and Chromium -> text/uri-list
			WebURLPboardType (kUTTypeURL), //webkit proprietary: public.url
			WebURLNamePboardType (kUTTypeURLName), //webkit proprietary: public.url-name
			NSStringPboardType, // public.utf8-plain-text -> WKJS: text/plain
			NSFilenamesPboardType, // Finder -> text/uri-list & Files
		])
	} */

	// TODO: give some feedback when a url is being dragged in to indicate what will happen
	//  (-[WKWebView draggingEntered:]):
	//  (-[WKWebView draggingUpdated:]):
	//  (-[WKWebView draggingExited:]):
	//  (-[WKWebView prepareForDragOperation:]):

	// try to accept DnD'd links from other browsers more gracefully than default WebKit behavior
	// this mess ain't funny: https://hsivonen.fi/kesakoodi/clipboard/
	override func performDragOperation(sender: NSDraggingInfo) -> Bool {
		if sender.draggingSource() == nil { //dragged from external application
			let pboard = sender.draggingPasteboard()

			if let file = pboard.stringForType(kUTTypeFileURL as String) { //drops from Finder
				warn("DnD: file from Finder: \(file)")
			} else {
				pboard.dump()
				pboard.normalizeURLDrag() // *cough* Trello! *cough*
				pboard.dump()
			}

			if let urls = pboard.readObjectsForClasses([NSURL.self], options: nil) {
				if jsdelegate.tryFunc("handleDragAndDroppedURLs", urls.map({$0.description})) {
			 		return true  // app.js indicated it handled drag itself
				}
			}
		} // -from external app

		return super.performDragOperation(sender)
		// if current page doesn't have HTML5 DnD event observers, webview will just navigate to URL dropped in
	}

/*
	// allow controlling drags out of a MacPin window
	override func beginDraggingSessionWithItems(items: [AnyObject], event: NSEvent, source: NSDraggingSource) -> NSDraggingSession {
		// API didn't land in 10.11.3 ... https://bugs.webkit.org/show_bug.cgi?id=143618
		warn()
		return super.beginDraggingSessionWithItems(items, event: event, source: source)
		//  (-[WKWebView _setDragImage:at:linkDrag:]):
		// https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/DragandDrop/Concepts/dragsource.html#//apple_ref/doc/uid/20000976-CJBFBADF
		// https://developer.apple.com/library/mac/documentation/Cocoa/Reference/ApplicationKit/Classes/NSView_Class/index.html#//apple_ref/occ/instm/NSView/beginDraggingSessionWithItems:event:source:
	}
*/

	//func dumpImage() -> NSImage { return NSImage(data: view.dataWithPDFInsideRect(view.bounds)) }
	func copyAsPDF() {
		let pb = NSPasteboard.generalPasteboard()
		pb.clearContents()
		writePDFInsideRect(bounds, toPasteboard: pb)
	}

	func printWebView(sender: AnyObject?) { _printOperationWithPrintInfo(NSPrintInfo.sharedPrintInfo()) }

	func console() {
		if let wkview = topFrame {
			let inspector = WKPageGetInspector(wkview.pageRef)
			WKInspectorShowConsole(inspector); // ShowConsole, Hide, Close, IsAttatched, Attach, Detach
		}
	}

#endif
}
