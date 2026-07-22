import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { P, S } from "./strings";

interface ServerEntry { url: string; label: string; }
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

$("prefs-title").textContent = P.title;
$("servers-title").textContent = P.servers;
$("prefs-add-btn").textContent = P.add;
$("autostart-label").textContent = P.launchAtLogin;
($("prefs-url") as HTMLInputElement).placeholder = S.urlPlaceholder;

async function renderServers() {
  const servers = await invoke<ServerEntry[]>("list_servers");
  const list = $("prefs-server-list");
  list.innerHTML = "";
  for (const s of servers) {
    const li = document.createElement("li");
    const open = document.createElement("button");
    open.className = "server-open";
    open.textContent = s.label;
    open.addEventListener("click", async () => {
      await invoke("set_active_server", { url: s.url });
      await getCurrentWindow().hide();
    });
    const rm = document.createElement("button");
    rm.className = "server-remove";
    rm.textContent = S.remove;
    rm.addEventListener("click", async (e) => {
      e.stopPropagation();
      await invoke("remove_server", { url: s.url });
      renderServers();
    });
    li.append(open, rm);
    list.append(li);
  }
}

$("prefs-add").addEventListener("submit", async (e) => {
  e.preventDefault();
  const url = ($("prefs-url") as HTMLInputElement).value.trim();
  if (!url) return;
  $("prefs-status").textContent = S.checking;
  try {
    const ok = await invoke<boolean>("check_server", { url });
    if (!ok) { $("prefs-status").textContent = S.unreachable; return; }
    await invoke("add_server", { url, label: "" });
    ($("prefs-url") as HTMLInputElement).value = "";
    $("prefs-status").textContent = "";
    renderServers();
  } catch (err) {
    $("prefs-status").textContent = String(err).includes("Invalid") ? S.invalidUrl : S.unreachable;
  }
});

const autostart = $("autostart") as HTMLInputElement;
invoke<boolean>("get_launch_at_login").then((v) => (autostart.checked = v));
autostart.addEventListener("change", () => invoke("set_launch_at_login", { enabled: autostart.checked }));

renderServers();
