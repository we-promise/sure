use serde::Deserialize;
use tauri::Listener;
use tauri_plugin_notification::NotificationExt;

#[derive(Deserialize)]
struct NotifyPayload {
    title: String,
    body: String,
}

pub fn register(app: &tauri::AppHandle) {
    let handle = app.clone();
    app.listen("bridge://notify", move |event| {
        if let Ok(p) = serde_json::from_str::<NotifyPayload>(event.payload()) {
            let _ = handle
                .notification()
                .builder()
                .title(p.title)
                .body(p.body)
                .show();
        }
    });
}
