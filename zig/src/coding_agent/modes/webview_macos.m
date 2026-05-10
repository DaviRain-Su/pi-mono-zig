#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <dispatch/dispatch.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

static char pi_webview_last_error_buffer[1024] = {0};
typedef char *(*PiWebViewHandleRequestFn)(void *context, const char *json, const char *origin);
typedef void (*PiWebViewFreeResponseFn)(void *context, char *response);
typedef void (*PiWebViewCloseActiveWorkFn)(void *context);

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

static double pi_webview_monotonic_ms(void) {
    return [[NSProcessInfo processInfo] systemUptime] * 1000.0;
}

static BOOL pi_webview_env_enabled(const char *name) {
    const char *value = getenv(name);
    if (value == NULL) {
        return NO;
    }
    return strcmp(value, "1") == 0 || strcmp(value, "true") == 0 || strcmp(value, "yes") == 0;
}

static long pi_webview_env_positive_long(const char *name, long default_value) {
    const char *value = getenv(name);
    if (value == NULL || value[0] == '\0') {
        return default_value;
    }
    char *end = NULL;
    long parsed = strtol(value, &end, 10);
    if (end == value || parsed < 0) {
        return default_value;
    }
    return parsed;
}

static NSString *pi_webview_json_string_literal(NSString *value) {
    NSString *safeValue = value ?: @"";
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[safeValue] options:0 error:&error];
    if (data == nil || error != nil) {
        return @"\"\"";
    }
    NSString *arrayJson = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (arrayJson == nil || [arrayJson length] < 2) {
        return @"\"\"";
    }
    return [arrayJson substringWithRange:NSMakeRange(1, [arrayJson length] - 2)];
}

static NSString *pi_webview_safe_telemetry_string(id value) {
    if (![value isKindOfClass:[NSString class]]) {
        return @"unknown";
    }
    NSString *text = (NSString *)value;
    if ([text length] == 0 || [text length] > 80) {
        return @"redacted";
    }
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    if ([text rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) {
        return @"redacted";
    }
    return text;
}

static double pi_webview_telemetry_number(NSDictionary *payload, NSString *key) {
    id value = payload[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value doubleValue];
    }
    return -1.0;
}

static const char *pi_webview_telemetry_bool(NSDictionary *payload, NSString *key) {
    id value = payload[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue] ? "true" : "false";
    }
    return "unknown";
}

static NSDictionary *pi_webview_json_object_from_string(NSString *json) {
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) {
        return nil;
    }
    NSError *error = nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error != nil || ![decoded isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return (NSDictionary *)decoded;
}

static void pi_webview_log_telemetry(NSDictionary *payload) {
    NSString *name = pi_webview_safe_telemetry_string(payload[@"name"]);
    NSString *provider = pi_webview_safe_telemetry_string(payload[@"provider"]);
    NSString *toolName = pi_webview_safe_telemetry_string(payload[@"toolName"]);
    NSString *terminalOutcome = pi_webview_safe_telemetry_string(payload[@"terminalOutcome"]);
    fprintf(
        stderr,
        "PI_WEBVIEW_TELEMETRY name=%s pid=%d host_monotonic_ms=%.3f perf_ms=%.3f wall_ms=%.0f since_launch_ms=%.3f since_ready_ms=%.3f since_hydrated_ms=%.3f provider=%s faux_provider=%s api_key_present=%s bridge_available=%s ready_to_focus_ms=%.3f ready_to_type_ms=%.3f hydrated_to_focus_ms=%.3f hydrated_to_type_ms=%.3f value_length=%.0f submit_to_visible_ms=%.3f submit_to_running_ms=%.3f submit_to_first_delta_ms=%.3f submit_to_terminal_ms=%.3f abort_to_visible_ms=%.3f error_to_retry_ready_ms=%.3f sequence=%.0f visible_delta_index=%.0f child_count=%.0f reused_surface=%s expanded=%s visible_in_answer=%s tool_name=%s terminal_outcome=%s max_active_frame_gap_ms=%.3f stall_over_100=%s\n",
        [name UTF8String],
        getpid(),
        pi_webview_monotonic_ms(),
        pi_webview_telemetry_number(payload, @"perfMs"),
        pi_webview_telemetry_number(payload, @"wallMs"),
        pi_webview_telemetry_number(payload, @"sinceLaunchMs"),
        pi_webview_telemetry_number(payload, @"sinceReadyMs"),
        pi_webview_telemetry_number(payload, @"sinceHydratedMs"),
        [provider UTF8String],
        [provider isEqualToString:@"faux"] ? "true" : "false",
        pi_webview_telemetry_bool(payload, @"apiKeyPresent"),
        pi_webview_telemetry_bool(payload, @"bridgeAvailable"),
        pi_webview_telemetry_number(payload, @"readyToFocusMs"),
        pi_webview_telemetry_number(payload, @"readyToTypeMs"),
        pi_webview_telemetry_number(payload, @"hydratedToFocusMs"),
        pi_webview_telemetry_number(payload, @"hydratedToTypeMs"),
        pi_webview_telemetry_number(payload, @"valueLength"),
        pi_webview_telemetry_number(payload, @"submitToVisibleMs"),
        pi_webview_telemetry_number(payload, @"submitToRunningMs"),
        pi_webview_telemetry_number(payload, @"submitToFirstDeltaMs"),
        pi_webview_telemetry_number(payload, @"submitToTerminalMs"),
        pi_webview_telemetry_number(payload, @"abortToVisibleMs"),
        pi_webview_telemetry_number(payload, @"errorToRetryReadyMs"),
        pi_webview_telemetry_number(payload, @"sequence"),
        pi_webview_telemetry_number(payload, @"visibleDeltaIndex"),
        pi_webview_telemetry_number(payload, @"childCount"),
        pi_webview_telemetry_bool(payload, @"reusedSurface"),
        pi_webview_telemetry_bool(payload, @"expanded"),
        pi_webview_telemetry_bool(payload, @"visibleInAnswer"),
        [toolName UTF8String],
        [terminalOutcome UTF8String],
        pi_webview_telemetry_number(payload, @"maxActiveFrameGapMs"),
        pi_webview_telemetry_bool(payload, @"stallOver100")
    );
    fflush(stderr);
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

        NSDictionary *messageObject = pi_webview_json_object_from_string(requestJson);
        NSString *messageType = [messageObject[@"type"] isKindOfClass:[NSString class]] ? (NSString *)messageObject[@"type"] : nil;
        if ([messageType isEqualToString:@"telemetry_mark"]) {
            pi_webview_log_telemetry(messageObject);
            return;
        }

        if ([messageType isEqualToString:@"frontend_ready"]) {
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
            NSWindow *window = [webView window];
            if (window != nil) {
                [window performClose:nil];
            } else {
                pi_webview_stop_app();
            }
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
@property(nonatomic) void *bridgeContext;
@property(nonatomic) PiWebViewCloseActiveWorkFn closeActiveWork;
@property(nonatomic) BOOL closeNotified;
@end

@implementation PiWebViewWindowDelegate
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    if (!self.closeNotified) {
        self.closeNotified = YES;
        if (self.closeActiveWork != NULL) {
            self.closeActiveWork(self.bridgeContext);
        }
        fprintf(stderr, "PI_WEBVIEW_WINDOW_CLOSE pid=%d\n", getpid());
        fflush(stderr);
    }
    pi_webview_stop_app();
}
@end

int pi_webview_macos_run(
    const char *asset_path,
    const char *window_title,
    int auto_close_ms,
    void *bridge_context,
    PiWebViewHandleRequestFn handle_request,
    PiWebViewFreeResponseFn free_response,
    PiWebViewCloseActiveWorkFn close_active_work
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
        const char *smokeInputUtf8 = getenv("PI_WEBVIEW_SMOKE_INPUT_TEXT");
        NSString *smokeInputText = smokeInputUtf8 != NULL ? [NSString stringWithUTF8String:smokeInputUtf8] : @"webview ready input smoke";
        if (smokeInputText == nil) {
            smokeInputText = @"webview ready input smoke";
        }
        const char *autoSubmitUtf8 = getenv("PI_WEBVIEW_SMOKE_AUTO_SUBMIT_PROMPT");
        const char *autoAbortUtf8 = getenv("PI_WEBVIEW_SMOKE_AUTO_ABORT_PROMPT");
        const char *autoProviderErrorUtf8 = getenv("PI_WEBVIEW_SMOKE_AUTO_PROVIDER_ERROR_PROMPT");
        const char *autoStructuredUtf8 = getenv("PI_WEBVIEW_SMOKE_AUTO_STRUCTURED_PROMPT");
        const char *selectedAutoSubmitUtf8 = autoSubmitUtf8;
        if (selectedAutoSubmitUtf8 == NULL || selectedAutoSubmitUtf8[0] == '\0') {
            selectedAutoSubmitUtf8 = autoAbortUtf8;
        }
        if (selectedAutoSubmitUtf8 == NULL || selectedAutoSubmitUtf8[0] == '\0') {
            selectedAutoSubmitUtf8 = autoProviderErrorUtf8;
        }
        if (selectedAutoSubmitUtf8 == NULL || selectedAutoSubmitUtf8[0] == '\0') {
            selectedAutoSubmitUtf8 = autoStructuredUtf8;
        }
        NSString *autoSubmitPrompt = selectedAutoSubmitUtf8 != NULL ? [NSString stringWithUTF8String:selectedAutoSubmitUtf8] : @"";
        if (autoSubmitPrompt == nil) {
            autoSubmitPrompt = @"";
        }
        long autoAbortMs = autoAbortUtf8 != NULL ? pi_webview_env_positive_long("PI_WEBVIEW_SMOKE_AUTO_ABORT_MS", 150) : 0;
        NSString *bootstrapScript = [NSString stringWithFormat:
            @"window.__PI_WEBVIEW_NATIVE_BOOTSTRAP__={launchMonotonicMs:%.3f,readyInputSmoke:%@,smokeInputText:%@,autoSubmitPrompt:%@,autoAbortMs:%ld};",
            pi_webview_monotonic_ms(),
            pi_webview_env_enabled("PI_WEBVIEW_SMOKE_READY_INPUT") ? @"true" : @"false",
            pi_webview_json_string_literal(smokeInputText),
            pi_webview_json_string_literal(autoSubmitPrompt),
            autoAbortMs
        ];
        WKUserScript *bootstrapUserScript = [[WKUserScript alloc] initWithSource:bootstrapScript
                                                                   injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                forMainFrameOnly:YES];
        [configuration.userContentController addUserScript:bootstrapUserScript];

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
        windowDelegate.bridgeContext = bridge_context;
        windowDelegate.closeActiveWork = close_active_work;
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
