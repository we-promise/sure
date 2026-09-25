//! Save the files a server sends as downloads.
//!
//! wry only turns a response into a download when WebKit cannot display it, so
//! a PDF or CSV sent with `Content-Disposition: attachment` replaced the page
//! instead of being saved. A browser saves it. [`save_attachments`] puts a
//! navigation delegate in front of wry's that makes the same choice, and passes
//! every other delegate call on to wry's delegate.

/// Whether a `Content-Disposition` header value asks for the body to be saved.
pub fn is_attachment(content_disposition: &str) -> bool {
    content_disposition
        .split(';')
        .next()
        .is_some_and(|kind| kind.trim().eq_ignore_ascii_case("attachment"))
}

#[cfg(target_os = "macos")]
pub use macos::save_attachments;

/// The delegate is specific to WKWebView, so other platforms keep wry's own
/// download handling.
#[cfg(not(target_os = "macos"))]
pub fn save_attachments(_window: &tauri::WebviewWindow) {}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::c_void;

    use objc2::rc::{Retained, Weak};
    use objc2::runtime::{AnyObject, NSObject, ProtocolObject};
    use objc2::{define_class, msg_send, DefinedClass, MainThreadMarker, MainThreadOnly};
    use objc2_foundation::{NSHTTPURLResponse, NSObjectProtocol, NSString};
    use objc2_web_kit::{
        WKDownload, WKNavigation, WKNavigationAction, WKNavigationActionPolicy,
        WKNavigationDelegate, WKNavigationResponse, WKNavigationResponsePolicy, WKWebView,
    };

    /// Associates the delegate with its webview, which retains it: the
    /// `navigationDelegate` property itself is weak.
    static DELEGATE_KEY: u8 = 0;

    struct Ivars {
        /// wry's delegate, which wry keeps alive as long as its webview. Held
        /// weakly: the webview retains this object, and wry's delegate retains
        /// the webview.
        wry: Weak<ProtocolObject<dyn WKNavigationDelegate>>,
    }

    define_class!(
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        #[name = "SureAttachmentNavigationDelegate"]
        #[ivars = Ivars]
        struct AttachmentNavigationDelegate;

        unsafe impl NSObjectProtocol for AttachmentNavigationDelegate {}

        // The delegate methods wry 0.55 implements, each passed on to wry's
        // delegate while it exists. They are explicit rather than forwarded, so
        // a call arriving once wry's delegate is gone is dropped instead of
        // raising an unrecognized selector exception; policy calls still get a
        // decision.
        unsafe impl WKNavigationDelegate for AttachmentNavigationDelegate {
            #[unsafe(method(webView:decidePolicyForNavigationAction:decisionHandler:))]
            fn decide_policy_for_navigation_action(
                &self,
                web_view: &WKWebView,
                navigation_action: &WKNavigationAction,
                decision_handler: &block2::DynBlock<dyn Fn(WKNavigationActionPolicy)>,
            ) {
                match self.ivars().wry.load() {
                    Some(wry) => unsafe {
                        wry.webView_decidePolicyForNavigationAction_decisionHandler(
                            web_view,
                            navigation_action,
                            decision_handler,
                        );
                    },
                    None => decision_handler.call((WKNavigationActionPolicy::Cancel,)),
                }
            }

            #[unsafe(method(webView:decidePolicyForNavigationResponse:decisionHandler:))]
            fn decide_policy_for_navigation_response(
                &self,
                web_view: &WKWebView,
                navigation_response: &WKNavigationResponse,
                decision_handler: &block2::DynBlock<dyn Fn(WKNavigationResponsePolicy)>,
            ) {
                match self.ivars().wry.load() {
                    Some(_) if response_is_attachment(navigation_response) => {
                        decision_handler.call((WKNavigationResponsePolicy::Download,));
                    }
                    Some(wry) => unsafe {
                        wry.webView_decidePolicyForNavigationResponse_decisionHandler(
                            web_view,
                            navigation_response,
                            decision_handler,
                        );
                    },
                    None => decision_handler.call((WKNavigationResponsePolicy::Cancel,)),
                }
            }

            #[unsafe(method(webView:didCommitNavigation:))]
            fn did_commit_navigation(
                &self,
                web_view: &WKWebView,
                navigation: Option<&WKNavigation>,
            ) {
                if let Some(wry) = self.ivars().wry.load() {
                    unsafe { wry.webView_didCommitNavigation(web_view, navigation) };
                }
            }

            #[unsafe(method(webView:didFinishNavigation:))]
            fn did_finish_navigation(
                &self,
                web_view: &WKWebView,
                navigation: Option<&WKNavigation>,
            ) {
                if let Some(wry) = self.ivars().wry.load() {
                    unsafe { wry.webView_didFinishNavigation(web_view, navigation) };
                }
            }

            #[unsafe(method(webView:navigationAction:didBecomeDownload:))]
            fn navigation_action_did_become_download(
                &self,
                web_view: &WKWebView,
                navigation_action: &WKNavigationAction,
                download: &WKDownload,
            ) {
                if let Some(wry) = self.ivars().wry.load() {
                    unsafe {
                        wry.webView_navigationAction_didBecomeDownload(
                            web_view,
                            navigation_action,
                            download,
                        );
                    }
                }
            }

            #[unsafe(method(webView:navigationResponse:didBecomeDownload:))]
            fn navigation_response_did_become_download(
                &self,
                web_view: &WKWebView,
                navigation_response: &WKNavigationResponse,
                download: &WKDownload,
            ) {
                if let Some(wry) = self.ivars().wry.load() {
                    unsafe {
                        wry.webView_navigationResponse_didBecomeDownload(
                            web_view,
                            navigation_response,
                            download,
                        );
                    }
                }
            }

            #[unsafe(method(webViewWebContentProcessDidTerminate:))]
            fn web_content_process_did_terminate(&self, web_view: &WKWebView) {
                if let Some(wry) = self.ivars().wry.load() {
                    unsafe { wry.webViewWebContentProcessDidTerminate(web_view) };
                }
            }
        }
    );

    fn response_is_attachment(navigation_response: &WKNavigationResponse) -> bool {
        let response = unsafe { navigation_response.response() };
        let Some(http) = response.downcast_ref::<NSHTTPURLResponse>() else {
            return false;
        };
        let header = NSString::from_str("Content-Disposition");
        http.valueForHTTPHeaderField(&header)
            .is_some_and(|value| super::is_attachment(&value.to_string()))
    }

    /// Save attachment responses of this window's webview into Downloads,
    /// through wry's download handling and so the window's `on_download`.
    pub fn save_attachments(window: &tauri::WebviewWindow) {
        let result = window.with_webview(|platform| {
            // SAFETY: on macOS tauri passes a WKWebView, its content controller
            // and its NSWindow, each retained for this call and never released.
            // Taking the references back releases them when this closure ends.
            let web_view = unsafe { Retained::<WKWebView>::from_raw(platform.inner().cast()) };
            drop(unsafe { Retained::<AnyObject>::from_raw(platform.controller().cast()) });
            drop(unsafe { Retained::<AnyObject>::from_raw(platform.ns_window().cast()) });
            // The closure runs on the main thread.
            let (Some(web_view), Some(mtm)) = (web_view, MainThreadMarker::new()) else {
                return;
            };
            let Some(wry) = (unsafe { web_view.navigationDelegate() }) else {
                return;
            };
            let delegate = mtm
                .alloc::<AttachmentNavigationDelegate>()
                .set_ivars(Ivars {
                    wry: Weak::from_retained(&wry),
                });
            let delegate: Retained<AttachmentNavigationDelegate> =
                unsafe { msg_send![super(delegate), init] };
            unsafe {
                objc2::ffi::objc_setAssociatedObject(
                    Retained::as_ptr(&web_view).cast_mut().cast(),
                    (&DELEGATE_KEY as *const u8).cast::<c_void>(),
                    Retained::as_ptr(&delegate).cast_mut().cast(),
                    objc2::ffi::OBJC_ASSOCIATION_RETAIN_NONATOMIC,
                );
                web_view.setNavigationDelegate(Some(ProtocolObject::from_ref(&*delegate)));
            }
        });
        if let Err(error) = result {
            eprintln!("[sure] failed to enable attachment downloads: {error}");
        }
    }
}
