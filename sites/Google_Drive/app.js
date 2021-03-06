/*eslint-env applescript*/
/*eslint-env es6*/
/*eslint eqeqeq:0, quotes:0, space-infix-ops:0, curly:0*/
"use strict";

var delegate = {}; // our delegate to receive events from the webview app
var driveTab, drive = {
	transparent: false,
	url: "https://drive.google.com",
	postinject: [],
	preinject: ['shim_html5_notifications'],
	subscribeTo: ['receivedHTML5DesktopNotification', "MacPinPollStates"]
};
var driveAlt = Object.assign({}, drive, {url: "https://drive.google.com/drive/u/1"});
var sheets = Object.assign({}, drive, {url: "https://docs.google.com/spreadsheets/"});
var docs = Object.assign({}, drive, {url: "https://docs.google.com/document/"});
var presentation = Object.assign({}, drive, {url: "https://docs.google.com/presentation/"});

/*
// ?authuser=N always overrides /u/N/ in the url!
// authuser= can also be a gmail or google apps email address

func gotoAlternateGoogleAccount(tab, acct) {
    // https://support.google.com/drive/answer/2405894?hl=en
	tab = tab || $.browser.tabSelected
	acct = acct || 1
	url.query['authuser'] = acct
	if (tab.url.test(//)) {
		tab.url = `${tab.url}/u/${acct}/`
	}
}
func gotoNextGoogleAccount(tab) {
    // https://support.google.com/drive/answer/2405894?hl=en
	tab = tab || $.browser.tabSelected
	acct = tab.uri.query["authuser"]  || 0
	url.query['authuser'] = acct + 1
	}
}

// do these with JS:gapi.auth2.*?
// https://github.com/google/google-api-javascript-client/issues/13
*/

driveTab = $.browser.tabSelected = new $.WebView(drive);

// dark mode: https://userstyles.org/styles/105045/google-drive-dark

function search(query) {
	driveTab.evalJS( // hook app.js to perform search
		""
 	);
}

delegate.launchURL = function(url) {
	var comps = url.split(':'),
		scheme = comps.shift(),
		addr = comps.shift();
	switch (scheme + ':') {
		case 'file':
			// check to see if its a JSON-ic .gdoc|gsheet|gslides from the Google Drive sync app
			//    if so, extract the link and pop the doc open
			// else, prompt to do upload
			driveTab.evalJS('confirm("Upload '+addr+'?");');
			break;
		case 'googledrive:':
		case 'gdrive:':
			$.browser.unhideApp();
			$.browser.tabSelected = driveTab;
			search(decodeURI(addr));
			break;
		default:
			$.browser.tabSelected = new $.WebView({url: url});
	}
};

var alwaysAllowRedir = false;
delegate.toggleRedirection = function(state) { alwaysAllowRedir = (state) ? true : false; };

delegate.decideNavigationForURL = function(url, tab) {
	var comps = url.split(':'),
		scheme = comps.shift(),
		addr = comps.shift();
	switch (scheme) {
		case "http":
		case "https":
			if (alwaysAllowRedir) break; //user override
			if ((addr.startsWith("//drive.google.com/") || addr.startsWith("//docs.google.com/")) && tab.allowAnyRedir) {
				tab.allowAnyRedir = false; // we are back home
			} else if (tab.allowAnyRedir || unescape(unescape(addr)).match("//accounts.google.com/")) {
				// we might be redirected to an external domain for a SSO-integrated Google Apps login
				// https://support.google.com/a/answer/60224#userSSO
				tab.allowAnyRedir = true;
			} else if (!~addr.indexOf("//drive.google.com") &&
				!~addr.indexOf("//docs.google.com") &&
				!~addr.indexOf(".docs.google.com") &&
				!~addr.indexOf("//clients6.google.com") &&
				!~addr.indexOf("//clients5.google.com") &&
				!~addr.indexOf("//clients4.google.com") &&
				!~addr.indexOf("//clients3.google.com") &&
				!~addr.indexOf("//clients2.google.com") &&
				!~addr.indexOf("//clients1.google.com") &&
				!~addr.indexOf("//clients.google.com") &&
				!~addr.indexOf("//plus.google.com") &&
				!~addr.indexOf("//0.client-channel.google.com") &&
				!~addr.indexOf("//1.client-channel.google.com") &&
				!~addr.indexOf("//2.client-channel.google.com") &&
				!~addr.indexOf("//3.client-channel.google.com") &&
				!~addr.indexOf("//4.client-channel.google.com") &&
				!~addr.indexOf("//5.client-channel.google.com") &&
				!~addr.indexOf("//6.client-channel.google.com") &&
				!~addr.indexOf("//apis.google.com") &&
				!~addr.indexOf("//0.talkgadget.google.com") &&
				!~addr.indexOf("//1.talkgadget.google.com") &&
				!~addr.indexOf("//2.talkgadget.google.com") &&
				!~addr.indexOf("//3.talkgadget.google.com") &&
				!~addr.indexOf("//4.talkgadget.google.com") &&
				!~addr.indexOf("//5.talkgadget.google.com") &&
				!~addr.indexOf("//6.talkgadget.google.com") &&
				!~addr.indexOf("//content.googleapis.com") &&
				!~addr.indexOf("//www.youtube.com") && // yt vids are usually embedded players
				!~addr.indexOf("//www.google.com/a/") &&
				!addr.startsWith("//myaccount.google.com") &&
				!addr.startsWith("//www.google.com/settings")
			) {
				$.app.openURL(url); //pop all external links to system browser
				console.log("opened "+url+" externally!");
				return true; //tell webkit to do nothing
			}
		case "about":
		case "file":
		default:
			return false;
	}
};

delegate.handleUserInputtedInvalidURL = function(query) {
	// assuming the invalid url is a search request
	search(query);
	return true; // tell MacPin to stop validating the URL
};

// handles all URLs drag-and-dropped into NON-html5 parts of Drive and Dock icon.
delegate.handleDragAndDroppedURLs = function(urls) {
	console.log(urls);
	for (var url of urls) {
		this.launchURL(url);
		//$.browser.tabSelected = new $.WebView({url: url});
	}
}

delegate.receivedHTML5DesktopNotification = function(tab, note) {
	console.log(Date() + ' [posted HTML5 notification] ' + note);
	$.app.postHTML5Notification(note);
};

delegate.handleClickedNotification = function(from, url, msg) { $.app.openURL(url); return true; };

delegate.AppFinishedLaunching = function() {
	$.app.registerURLScheme('gdrive');
	//$.app.registerURLScheme('googledrive'); //iOS
	$.browser.addShortcut('Drive', drive);
	$.browser.addShortcut('Drive (using secondary account)', driveAlt);
	$.browser.addShortcut('Sheets', sheets);
	$.browser.addShortcut('Docs', docs);
	$.browser.addShortcut('Presentations', presentation);
	$.browser.addShortcut("Add a Google log-in", 'https://accounts.google.com/AddSession');
	$.browser.addShortcut('Use next Google log-in', ['gotoNextGoogleAccount']);
	$.browser.addShortcut("Install 'Open in Google Drive app' service", `http://github.com/kfix/MacPin/tree/master/extras/${escape('Open in Google Drive app.workflow')}`);
	$.browser.addShortcut('Enable Redirection to external domains', ['toggleRedirection', true]);
	$.browser.addShortcut('Disable Redirection (default)', ['toggleRedirection', false]);

	if ($.launchedWithURL != '') { // app was launched with a search query
		driveTab.asyncEvalJS( // need to wait for app.js to load and render DOM
			"true;",
			5, // delay (in seconds) to wait for tab to load
			function(result) { // callback
				delegate.launchURL($.launchedWithURL);
				$.launchedWithURL = '';
			}
		);
	}

};
delegate; //return this to macpin
