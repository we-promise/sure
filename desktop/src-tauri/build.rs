fn main() {
    let bridge = std::path::Path::new("../dist/bridge.js");
    if !bridge.exists() {
        if let Some(parent) = bridge.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(bridge, "/* bridge placeholder */");
    }
    tauri_build::build();
}
