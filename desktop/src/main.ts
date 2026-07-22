import { invoke } from "@tauri-apps/api/core";
import { S } from "./strings";

interface ServerEntry { url: string; label: string; }

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

function fill() {
  $("title").textContent = S.title;
  $("subtitle").textContent = S.subtitle;
  ($("server-url") as HTMLInputElement).placeholder = S.urlPlaceholder;
  $("connect").textContent = S.connect;
  $("remembered-title").textContent = S.remembered;
}

function setStatus(msg: string, kind: "info" | "error" = "info") {
  const el = $("status");
  el.textContent = msg;
  el.dataset.kind = kind;
}

async function connect(rawUrl: string) {
  setStatus(S.checking, "info");
  let healthy: boolean;
  try {
    healthy = await invoke<boolean>("check_server", { url: rawUrl });
  } catch (e) {
    setStatus(String(e).includes("Invalid") ? S.invalidUrl : S.unreachable, "error");
    return;
  }
  if (!healthy) { setStatus(S.unreachable, "error"); return; }
  const list = await invoke<ServerEntry[]>("add_server", { url: rawUrl, label: "" });
  const canonical = list[0].url;
  await invoke("set_active_server", { url: canonical });
  window.location.assign(`${canonical}/session/new`);
}

async function renderRemembered() {
  const servers = await invoke<ServerEntry[]>("list_servers");
  const section = $("remembered");
  const listEl = $("server-list");
  listEl.innerHTML = "";
  if (servers.length === 0) { section.classList.add("hidden"); return; }
  section.classList.remove("hidden");
  for (const s of servers) {
    const li = document.createElement("li");
    const open = document.createElement("button");
    open.className = "server-open";
    open.textContent = s.label;
    open.addEventListener("click", () => connect(s.url));
    const rm = document.createElement("button");
    rm.className = "server-remove";
    rm.textContent = S.remove;
    rm.addEventListener("click", async (e) => {
      e.stopPropagation();
      await invoke("remove_server", { url: s.url });
      renderRemembered();
    });
    li.append(open, rm);
    listEl.append(li);
  }
}

fill();
renderRemembered();
$("server-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const url = ($("server-url") as HTMLInputElement).value.trim();
  if (url) connect(url);
});
