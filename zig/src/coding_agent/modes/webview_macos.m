#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static char pi_webview_last_error_buffer[1024] = {0};
typedef char *(*PiWebViewHandleRequestFn)(void *context, const char *json, const char *origin);
typedef void (*PiWebViewFreeResponseFn)(void *context, char *response);

static void pi_webview_set_last_error(NSString *message) {
    const char *utf8 = message ? [message UTF8String] : "unknown error";
    if (utf8 == NULL) {
        utf8 = "unknown error";
    }
    snprintf(pi_webview_last_error_buffer, sizeof(pi_webview_last_error_buffer), "%s", utf8);
}

static const char *pi_webview_redacted_url(NSURL *URL) {
    static char redacted_url_buffer[512] = {0};
    if (URL == nil) {
        snprintf(redacted_url_buffer, sizeof(redacted_url_buffer), "<nil>");
        return redacted_url_buffer;
    }

    NSString *scheme = [URL scheme] ?: @"unknown";
    if ([URL isFileURL]) {
        snprintf(redacted_url_buffer, sizeof(redacted_url_buffer), "%s://[local-file]", [scheme UTF8String]);
        return redacted_url_buffer;
    }

    NSString *host = [URL host];
    if (host != nil && [host length] > 0) {
        snprintf(redacted_url_buffer, sizeof(redacted_url_buffer), "%s://%s/[redacted]", [scheme UTF8String], [host UTF8String]);
    } else {
        snprintf(redacted_url_buffer, sizeof(redacted_url_buffer), "%s://[redacted]", [scheme UTF8String]);
    }
    return redacted_url_buffer;
}

const char *pi_webview_macos_last_error(void) {
    if (pi_webview_last_error_buffer[0] == '\0') {
        return NULL;
    }
    return pi_webview_last_error_buffer;
}

static void pi_webview_stop_app(void) {
    [NSApp stop:nil];
    NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0];
    [NSApp postEvent:event atStart:NO];
}

@interface PiWebViewBridgeHandler : NSObject <WKScriptMessageHandler>
@property(nonatomic) void *bridgeContext;
@property(nonatomic) PiWebViewHandleRequestFn handleRequest;
@property(nonatomic) PiWebViewFreeResponseFn freeResponse;
@property(nonatomic, weak) WKWebView *webView;
@end

@implementation PiWebViewBridgeHandler
- (NSString *)jsonStringForMessageBody:(id)body {
    if ([body isKindOfClass:[NSString class]]) {
        return (NSString *)body;
    }
    if (![NSJSONSerialization isValidJSONObject:body]) {
        return nil;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];
    if (data == nil || error != nil) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)userContentController;
    if ([message.name isEqualToString:@"pi"]) {
        WKWebView *webView = self.webView;
        NSString *requestJson = [self jsonStringForMessageBody:message.body];
        if (requestJson == nil || self.handleRequest == NULL) {
            fprintf(stderr, "PI_WEBVIEW_BRIDGE_ERROR pid=%d reason=invalid_request\n", getpid());
            fflush(stderr);
            return;
        }

        if ([requestJson containsString:@"frontend_ready"]) {
            fprintf(stderr, "PI_WEBVIEW_BRIDGE_READY pid=%d\n", getpid());
            fflush(stderr);
            return;
        }

        const char *requestUtf8 = [requestJson UTF8String];
        char *response = self.handleRequest(self.bridgeContext, requestUtf8, "pi-webview://bundle");
        if (response == NULL) {
            fprintf(stderr, "PI_WEBVIEW_BRIDGE_ERROR pid=%d reason=handler_returned_null\n", getpid());
            fflush(stderr);
            return;
        }

        NSString *responseJson = [NSString stringWithUTF8String:response];
        if (responseJson != nil && webView != nil) {
            NSString *script = [NSString stringWithFormat:@"window.piBridgeReceive && window.piBridgeReceive(%@);", responseJson];
            dispatch_async(dispatch_get_main_queue(), ^{
                [webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
                    (void)result;
                    if (error != nil) {
                        fprintf(stderr, "PI_WEBVIEW_BRIDGE_EVAL_FAILED pid=%d error=%s\n", getpid(), [[error localizedDescription] UTF8String]);
                        fflush(stderr);
                    }
                }];
            });
        }
        self.freeResponse(self.bridgeContext, response);
        fprintf(stderr, "PI_WEBVIEW_BRIDGE_REQUEST pid=%d bytes=%lu\n", getpid(), (unsigned long)[requestJson length]);
        fflush(stderr);
    }
}
@end

@interface PiWebViewNavigationDelegate : NSObject <WKNavigationDelegate>
@property(nonatomic, copy) NSString *assetPath;
@property(nonatomic, copy) NSString *assetRootPath;
@property(nonatomic) int autoCloseMs;
@end

@implementation PiWebViewNavigationDelegate
- (BOOL)isTrustedURL:(NSURL *)URL {
    if (URL == nil || ![URL isFileURL]) {
        return NO;
    }

    NSString *path = [[URL path] stringByResolvingSymlinksInPath];
    NSString *root = [self.assetRootPath stringByResolvingSymlinksInPath];
    if (path == nil || root == nil || [path length] == 0 || [root length] == 0) {
        return NO;
    }

    if ([path isEqualToString:root]) {
        return YES;
    }

    NSString *rootWithSlash = [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
    return [path hasPrefix:rootWithSlash];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                     decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    NSURL *URL = [[navigationAction request] URL];
    if ([navigationAction targetFrame] == nil) {
        fprintf(stderr, "PI_WEBVIEW_POPUP_DENIED pid=%d url=%s\n", getpid(), pi_webview_redacted_url(URL));
        fflush(stderr);
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    if (![self isTrustedURL:URL]) {
        fprintf(stderr, "PI_WEBVIEW_NAVIGATION_DENIED pid=%d url=%s\n", getpid(), pi_webview_redacted_url(URL));
        fflush(stderr);
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView;
    (void)navigation;
    fprintf(stderr, "PI_WEBVIEW_READY pid=%d asset=%s bridge=registered\n", getpid(), [self.assetPath UTF8String]);
    fflush(stderr);

    if (self.autoCloseMs > 0) {
        dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)self.autoCloseMs * NSEC_PER_MSEC);
        dispatch_after(deadline, dispatch_get_main_queue(), ^{
            pi_webview_stop_app();
        });
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView;
    (void)navigation;
    pi_webview_set_last_error([error localizedDescription]);
    fprintf(stderr, "PI_WEBVIEW_LOAD_FAILED pid=%d error=%s\n", getpid(), [[error localizedDescription] UTF8String]);
    fflush(stderr);
    pi_webview_stop_app();
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}
@end

@interface PiWebViewUIDelegate : NSObject <WKUIDelegate>
@end

@implementation PiWebViewUIDelegate
- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
    (void)webView;
    (void)configuration;
    (void)windowFeatures;
    NSURL *URL = [[navigationAction request] URL];
    fprintf(stderr, "PI_WEBVIEW_POPUP_DENIED pid=%d url=%s\n", getpid(), pi_webview_redacted_url(URL));
    fflush(stderr);
    return nil;
}
@end

@interface PiWebViewWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation PiWebViewWindowDelegate
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    pi_webview_stop_app();
}
@end

int pi_webview_macos_run(
    const char *asset_path,
    const char *window_title,
    int auto_close_ms,
    void *bridge_context,
    PiWebViewHandleRequestFn handle_request,
    PiWebViewFreeResponseFn free_response
) {
    pi_webview_last_error_buffer[0] = '\0';

    @autoreleasepool {
        if (asset_path == NULL || asset_path[0] == '\0') {
            pi_webview_set_last_error(@"missing WebView asset path");
            return 1;
        }

        NSString *assetPath = [NSString stringWithUTF8String:asset_path];
        if (assetPath == nil) {
            pi_webview_set_last_error(@"invalid UTF-8 WebView asset path");
            return 1;
        }

        BOOL isDirectory = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:assetPath isDirectory:&isDirectory] || isDirectory) {
            pi_webview_set_last_error([NSString stringWithFormat:@"WebView asset does not exist: %@", assetPath]);
            return 1;
        }

        NSString *title = window_title ? [NSString stringWithUTF8String:window_title] : @"pi WebView";
        if (title == nil) {
            title = @"pi WebView";
        }

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
        PiWebViewBridgeHandler *bridgeHandler = [[PiWebViewBridgeHandler alloc] init];
        bridgeHandler.bridgeContext = bridge_context;
        bridgeHandler.handleRequest = handle_request;
        bridgeHandler.freeResponse = free_response;
        [configuration.userContentController addScriptMessageHandler:bridgeHandler name:@"pi"];

        NSRect frame = NSMakeRect(0, 0, 1100, 760);
        NSWindow *window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        [window setTitle:title];
        [window center];

        WKWebView *webView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
        bridgeHandler.webView = webView;
        PiWebViewNavigationDelegate *navigationDelegate = [[PiWebViewNavigationDelegate alloc] init];
        navigationDelegate.assetPath = assetPath;
        navigationDelegate.assetRootPath = [assetPath stringByDeletingLastPathComponent];
        navigationDelegate.autoCloseMs = auto_close_ms;
        webView.navigationDelegate = navigationDelegate;
        PiWebViewUIDelegate *uiDelegate = [[PiWebViewUIDelegate alloc] init];
        webView.UIDelegate = uiDelegate;

        PiWebViewWindowDelegate *windowDelegate = [[PiWebViewWindowDelegate alloc] init];
        window.delegate = windowDelegate;
        window.contentView = webView;

        NSURL *assetURL = [NSURL fileURLWithPath:assetPath isDirectory:NO];
        NSURL *assetRootURL = [assetURL URLByDeletingLastPathComponent];
        [webView loadFileURL:assetURL allowingReadAccessToURL:assetRootURL];

        [window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];

        [configuration.userContentController removeScriptMessageHandlerForName:@"pi"];
        webView.navigationDelegate = nil;
        webView.UIDelegate = nil;
        window.delegate = nil;
        [window close];

        fprintf(stderr, "PI_WEBVIEW_NATIVE_CLEANUP pid=%d\n", getpid());
        fflush(stderr);
    }

    return pi_webview_last_error_buffer[0] == '\0' ? 0 : 1;
}
