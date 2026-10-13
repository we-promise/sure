use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::webview::{DownloadEvent, NewWindowResponse, PageLoadEvent, PageLoadPayload};
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder, Wry};
use tauri_plugin_decorum::WebviewWindowExt;
use tauri_plugin_notification::NotificationExt;
use url::Url;

static POPUP_WINDOW_ID: AtomicUsize = AtomicUsize::new(0);

/// Wait after a printable report loads before opening the print dialog. This
/// matches the delay in Sure's print layout, which lets styles settle.
const PRINT_DELAY: Duration = Duration::from_millis(500);

/// Ids of the toast templates Sure renders next to its notification tray, one
/// per download outcome.
const DOWNLOAD_COMPLETE_TOAST: &str = "desktop-download-complete";
const DOWNLOAD_FAILED_TOAST: &str = "desktop-download-failed";

pub fn setup(app: &tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    // Build the configured window here so native download and popup handlers
    // are attached before the webview loads the server.
    let config = app
        .config()
        .app
        .windows
        .iter()
        .find(|window| window.label == "main")
        .expect("main window configuration exists");
    let handle = app.handle().clone();
    let page = ShownPage::default();
    let window = WebviewWindowBuilder::from_config(app, config)?
        .on_page_load({
            let page = page.clone();
            move |_, payload| page.record(&payload)
        })
        .on_download({
            let page = page.clone();
            let refused = RefusedDownloads::default();
            move |webview, event| on_download(&page, &refused, webview, event)
        })
        .on_new_window(move |url, _| on_new_window(&handle, &page, url))
        .build()?;
    crate::attachments::save_attachments(&window);

    // The window is opaque (the app paints its own solid backgrounds), so we
    // skip the transparent-window vibrancy blur — it never showed through and
    // forced the compositor to re-blend the webview every frame (high GPU).

    // Overlay titlebar + inset traffic lights so content sits under a clean bar.
    window.create_overlay_titlebar()?;
    window.set_traffic_lights_inset(16.0, 20.0)?;

    Ok(())
}

/// Where a page's request to open a new window (a `target="_blank"` link or
/// `window.open`) should go.
#[derive(Debug, PartialEq, Eq)]
pub enum PopupAction {
    /// A page of a saved server opens in a Sure window that keeps the session.
    ServerWindow,
    /// Any other website opens in the default browser, which has no session.
    Browser,
    /// Anything else is ignored.
    Deny,
}

/// Decide where a popup goes. Popups are honored only while the opener window
/// shows a page of a saved server (`opener_trusted`). Frames embedded in that
/// page count as the page, because the requesting frame is not exposed. Only
/// plain http(s) addresses without credentials are opened, so no page can hand
/// other schemes to the system. `is_known_server` is injected so the policy can
/// be tested without the saved server list.
pub fn popup_action(
    url: &Url,
    opener_trusted: bool,
    is_known_server: impl Fn(&str) -> bool,
) -> PopupAction {
    if !opener_trusted || !is_plain_web_url(url) {
        return PopupAction::Deny;
    }
    if is_known_server(url.as_str()) {
        PopupAction::ServerWindow
    } else {
        PopupAction::Browser
    }
}

/// Extract the server mount from a printable-report URL, excluding all other
/// pages. The caller checks that this server was saved by the user.
pub fn print_report_server(url: &Url) -> Option<String> {
    if !is_plain_web_url(url) {
        return None;
    }
    let mount = url.path().strip_suffix("/reports/print")?;
    Some(format!("{}{mount}", url.origin().ascii_serialization()))
}

fn is_plain_web_url(url: &Url) -> bool {
    matches!(url.scheme(), "http" | "https")
        && url.username().is_empty()
        && url.password().is_none()
}

/// The page a window shows, recorded each time a navigation commits.
/// `WebviewWindow::url()` cannot stand in for it: WebKit already reports the
/// target of a pending navigation there, while the previous page still runs.
#[derive(Clone, Default)]
struct ShownPage(Arc<Mutex<Option<Url>>>);

impl ShownPage {
    fn record(&self, payload: &PageLoadPayload<'_>) {
        // wry reports Started from didCommitNavigation, when the page changes.
        if payload.event() == PageLoadEvent::Started {
            *self.0.lock().unwrap() = Some(payload.url().clone());
        }
    }

    fn is_saved_server(&self) -> bool {
        let page = self.0.lock().unwrap().clone();
        page.is_some_and(|page| crate::servers::is_known_server(page.as_str()))
    }
}

fn on_new_window(handle: &AppHandle, opener: &ShownPage, url: Url) -> NewWindowResponse<Wry> {
    let opener_trusted = opener.is_saved_server();
    match popup_action(&url, opener_trusted, crate::servers::is_known_server) {
        PopupAction::ServerWindow => open_server_window(handle, url),
        PopupAction::Browser => {
            if let Err(error) = open::that(url.as_str()) {
                eprintln!("[sure] failed to open link in the browser: {error}");
            }
        }
        PopupAction::Deny => {}
    }
    // Allowed popups are opened above, so WebKit never creates its own.
    NewWindowResponse::Deny
}

/// Open a page of a saved server in its own Sure window. It is a separate
/// webview rather than a WebKit popup, which would run on the main window's
/// configuration and so reach Rust through the main window's IPC handlers. Both
/// windows use the default website data store, so the session carries over.
/// Only the main window gets the bridge script and its desktop integrations.
fn open_server_window(handle: &AppHandle, url: Url) {
    let label = format!("popup-{}", POPUP_WINDOW_ID.fetch_add(1, Ordering::Relaxed));
    // Until a page commits, the window stands for the saved-server address it
    // was opened with, so a file served directly at that address can download.
    let page = ShownPage(Arc::new(Mutex::new(Some(url.clone()))));
    // Stays false when the address answers with a file, as a CSV statement
    // opened for viewing does: the window then never shows a page.
    let showed_page = Arc::new(AtomicBool::new(false));
    let popup_handle = handle.clone();
    let result = WebviewWindowBuilder::new(handle, label, WebviewUrl::External(url))
        .title("Sure")
        .inner_size(1000.0, 800.0)
        .on_page_load({
            let page = page.clone();
            let showed_page = showed_page.clone();
            move |window, payload| {
                if payload.event() == PageLoadEvent::Started {
                    showed_page.store(true, Ordering::Relaxed);
                }
                page.record(&payload);
                print_loaded_report(window, payload);
            }
        })
        .on_download({
            let page = page.clone();
            let refused = RefusedDownloads::default();
            move |webview, event| {
                let finished = matches!(event, DownloadEvent::Finished { .. });
                let window = webview.window();
                let allowed = on_download(&page, &refused, webview, event);
                if !showed_page.load(Ordering::Relaxed) {
                    dismiss_empty_popup(window, finished);
                }
                allowed
            }
        })
        .on_new_window(move |url, _| on_new_window(&popup_handle, &page, url))
        .on_document_title_changed(|window, title| {
            let _ = window.set_title(&title);
        })
        .build();
    match result {
        Ok(window) => crate::attachments::save_attachments(&window),
        Err(error) => eprintln!("[sure] failed to open window: {error}"),
    }
}

/// Hide a popup whose address answered with a file instead of a page, then
/// close it once the download ends. `close` is queued on the event loop, so the
/// webview, whose download delegate runs this callback, is destroyed only after
/// the callback returns.
fn dismiss_empty_popup(window: tauri::Window, download_finished: bool) {
    if download_finished {
        if let Err(error) = window.close() {
            eprintln!("[sure] failed to close an empty window: {error}");
        }
    } else if let Err(error) = window.hide() {
        eprintln!("[sure] failed to hide an empty window: {error}");
    }
}

/// Open the native print dialog once a printable report has loaded. Rust prints
/// the report's own webview; the page's `window.print()` has no IPC permission,
/// so it cannot open a second dialog.
fn print_loaded_report(window: WebviewWindow, payload: PageLoadPayload<'_>) {
    if payload.event() != PageLoadEvent::Finished
        || !print_report_server(payload.url())
            .is_some_and(|server| crate::servers::is_known_server(&server))
    {
        return;
    }
    std::thread::spawn(move || {
        std::thread::sleep(PRINT_DELAY);
        if let Err(error) = window.print() {
            eprintln!("[sure] failed to print report: {error}");
        }
    });
}

/// Downloads a window refused. WebKit ends a refused download as a failure for
/// the same request URL, which must not be reported to the user as one.
#[derive(Clone, Default)]
pub struct RefusedDownloads(Arc<Mutex<Vec<Url>>>);

impl RefusedDownloads {
    /// Remember the decision for a requested download, and return it.
    pub fn remember(&self, url: &Url, allowed: bool) -> bool {
        if !allowed {
            self.0.lock().unwrap().push(url.clone());
        }
        allowed
    }

    /// Whether a finished download is reported: all of them but the refused.
    pub fn should_report(&self, url: &Url, success: bool) -> bool {
        if success {
            return true;
        }
        let mut refused = self.0.lock().unwrap();
        match refused.iter().position(|refused_url| refused_url == url) {
            Some(index) => {
                refused.remove(index);
                false
            }
            None => true,
        }
    }
}

fn on_download(
    page: &ShownPage,
    refused: &RefusedDownloads,
    webview: tauri::Webview,
    event: DownloadEvent<'_>,
) -> bool {
    match event {
        // Only a page of a saved server may save files into Downloads.
        DownloadEvent::Requested { url, .. } => {
            let allowed = page.is_saved_server();
            if !allowed {
                eprintln!("[sure] blocked a download from a page outside saved servers");
            }
            refused.remember(&url, allowed)
        }
        DownloadEvent::Finished { url, success, .. } => {
            if refused.should_report(&url, success) {
                if !success {
                    eprintln!("[sure] download failed");
                }
                report_download(&webview, success);
            }
            true
        }
        _ => true,
    }
}

/// What the toast script reports: whether it showed Sure's toast, and the
/// toast's text in the page's language, for the native notification.
#[derive(Debug, Default, PartialEq, serde::Deserialize)]
pub struct DownloadToast {
    #[serde(default)]
    pub shown: bool,
    pub message: Option<String>,
    pub description: Option<String>,
}

impl DownloadToast {
    /// Read the script's result. `null`, from a page without the template (an
    /// older server), or any other unexpected value means no toast and no text.
    pub fn from_script_result(result: &str) -> Self {
        serde_json::from_str::<Option<Self>>(result)
            .ok()
            .flatten()
            .unwrap_or_default()
    }
}

/// Title and body of the native notification for a finished download: the
/// toast's own text when the page provides it, English otherwise.
pub fn download_notification(success: bool, toast: &DownloadToast) -> (String, String) {
    let message = toast.message.clone().filter(|text| !text.is_empty());
    let description = toast.description.clone().filter(|text| !text.is_empty());
    match (message, description) {
        (Some(message), Some(description)) => (message, description),
        (Some(message), None) => ("Sure".to_string(), message),
        // macOS does not return a path in Finished. Wry saves downloads to the
        // Downloads directory and adds a suffix when a filename already exists.
        (None, _) if success => (
            "Sure".to_string(),
            "Download complete. The file is in your Downloads folder.".to_string(),
        ),
        (None, _) => (
            "Sure".to_string(),
            "Download failed. Please try again.".to_string(),
        ),
    }
}

/// Confirm a finished download with Sure's own toast, cloned from a template the
/// page renders. A native notification replaces it when no visible window can
/// show it or the page has no such template, as with an older server, and is
/// sent as well when the window is not in front. It reuses the toast's text, so
/// it is in the page's language whenever the page provides the template.
fn report_download(webview: &tauri::Webview, success: bool) {
    let app = webview.app_handle().clone();
    // A popup hidden because its address was the file shows nothing.
    let target = if webview.window().is_visible().unwrap_or(false) {
        Some(webview.clone())
    } else {
        app.get_webview_window("main")
            .map(|main| main.as_ref().clone())
    };
    let Some(target) = target else {
        return notify_download(&app, success, &DownloadToast::default());
    };
    // A toast added to a hidden window would only show up, stale, on reopening,
    // so there the script only reads the text.
    let visible = target.window().is_visible().unwrap_or(false);
    let in_front = visible && target.window().is_focused().unwrap_or(false);
    let template = if success {
        DOWNLOAD_COMPLETE_TOAST
    } else {
        DOWNLOAD_FAILED_TOAST
    };
    let script = format!(
        "(() => {{
          const template = document.getElementById({template:?});
          if (!(template instanceof HTMLTemplateElement)) return null;
          const tray = document.getElementById(\"notification-tray\");
          const shown = {visible} && tray !== null;
          if (shown) tray.append(template.content.cloneNode(true));
          return {{
            shown,
            message: template.dataset.message ?? null,
            description: template.dataset.description ?? null,
          }};
        }})()"
    );
    let notify_app = app.clone();
    let evaluated = target.eval_with_callback(script, move |result| {
        let toast = DownloadToast::from_script_result(&result);
        if !toast.shown || !in_front {
            notify_download(&notify_app, success, &toast);
        }
    });
    if evaluated.is_err() {
        notify_download(&app, success, &DownloadToast::default());
    }
}

fn notify_download(app: &AppHandle, success: bool, toast: &DownloadToast) {
    let (title, body) = download_notification(success, toast);
    if let Err(error) = app.notification().builder().title(title).body(body).show() {
        eprintln!("[sure] failed to show download notification: {error}");
    }
}
