use std::sync::atomic::{AtomicUsize, Ordering};
use tauri::webview::{DownloadEvent, NewWindowResponse};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_decorum::WebviewWindowExt;
use tauri_plugin_notification::NotificationExt;

static REPORT_WINDOW_ID: AtomicUsize = AtomicUsize::new(0);

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
    let window = WebviewWindowBuilder::from_config(app, config)?
        .on_download(on_download)
        .on_new_window(move |url, features| {
            let Some(server) = print_report_server(&url) else {
                return NewWindowResponse::Deny;
            };
            if !crate::servers::is_known_server(&server) {
                return NewWindowResponse::Deny;
            }

            let label = format!(
                "report-{}",
                REPORT_WINDOW_ID.fetch_add(1, Ordering::Relaxed)
            );
            match WebviewWindowBuilder::new(
                &handle,
                label,
                WebviewUrl::External("about:blank".parse().unwrap()),
            )
            // WKWebView requires the opener's configuration. This also keeps
            // the authenticated server session when opening the report.
            .window_features(features)
            .title("Sure")
            .inner_size(1000.0, 800.0)
            .on_download(on_download)
            .on_document_title_changed(|window, title| {
                let _ = window.set_title(&title);
            })
            .build()
            {
                Ok(window) => NewWindowResponse::Create { window },
                Err(error) => {
                    eprintln!("[sure] failed to open report window: {error}");
                    NewWindowResponse::Deny
                }
            }
        })
        .build()?;

    // The window is opaque (the app paints its own solid backgrounds), so we
    // skip the transparent-window vibrancy blur — it never showed through and
    // forced the compositor to re-blend the webview every frame (high GPU).

    // Overlay titlebar + inset traffic lights so content sits under a clean bar.
    window.create_overlay_titlebar()?;
    window.set_traffic_lights_inset(16.0, 20.0)?;

    Ok(())
}

/// Extract the server mount from a printable-report URL, excluding all other
/// popup destinations. The caller checks that this server was saved by the user.
pub fn print_report_server(url: &url::Url) -> Option<String> {
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return None;
    }
    let mount = url.path().strip_suffix("/reports/print")?;
    Some(format!("{}{mount}", url.origin().ascii_serialization()))
}

fn on_download(webview: tauri::Webview, event: DownloadEvent<'_>) -> bool {
    if let DownloadEvent::Finished { success, .. } = event {
        // macOS does not return a path in Finished. Wry saves downloads to the
        // Downloads directory and adds a suffix when a filename already exists.
        let body = if success {
            "Download complete. The file is in your Downloads folder."
        } else {
            eprintln!("[sure] download failed");
            "Download failed. Please try again."
        };
        if let Err(error) = webview
            .app_handle()
            .notification()
            .builder()
            .title("Sure")
            .body(body)
            .show()
        {
            eprintln!("[sure] failed to show download notification: {error}");
        }
    }
    true
}
