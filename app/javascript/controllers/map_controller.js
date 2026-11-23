import { Controller } from "@hotwired/stimulus";
import L from "leaflet";
import "leaflet.markercluster";

// Connects to data-controller="map"
export default class extends Controller {
  static targets = ["container", "list"];
  static values = { points: Array, tileUrl: String, tileAttribution: String };

  connect() {
    this.map = L.map(this.containerTarget).setView([20, 0], 2);

    L.tileLayer(this.tileUrlValue, {
      attribution: this.tileAttributionValue,
      maxZoom: 19,
    }).addTo(this.map);

    const cluster = L.markerClusterGroup();

    this.pointsValue.forEach((point) => {
      const marker = L.marker([point.lat, point.lng]);
      marker.bindPopup(this.#popupHtml(point));
      cluster.addLayer(marker);
    });

    this.map.addLayer(cluster);

    if (this.pointsValue.length > 0) {
      this.map.fitBounds(cluster.getBounds(), { padding: [32, 32] });
    }

    this.#updateVisibleList();
    this.map.on("moveend", () => this.#updateVisibleList());
  }

  disconnect() {
    this.map?.remove();
  }

  // Keeps the list in sync with whatever the user is actually looking at,
  // rather than the full (possibly date/account-filtered) result set.
  #updateVisibleList() {
    if (!this.hasListTarget) return;

    const bounds = this.map.getBounds();
    const visible = this.pointsValue.filter((point) =>
      bounds.contains([point.lat, point.lng]),
    );
    this.#renderList(visible);
  }

  #renderList(points) {
    this.listTarget.replaceChildren(
      ...points.map((point) => this.#listItem(point)),
    );
  }

  #listItem(point) {
    const link = document.createElement("a");
    link.href = point.transaction_path;
    link.className =
      "flex items-center justify-between gap-2 p-2 rounded-lg hover:bg-container-hover";

    const text = document.createElement("div");
    text.className = "min-w-0";

    const name = document.createElement("p");
    name.className = "text-sm text-primary truncate";
    name.textContent = point.transaction_name;
    text.appendChild(name);

    const meta = document.createElement("p");
    meta.className = "text-xs text-secondary truncate";
    meta.textContent = `${point.name} · ${point.date}`;
    text.appendChild(meta);

    link.appendChild(text);

    const amount = document.createElement("p");
    amount.className = "text-sm text-primary whitespace-nowrap";
    amount.textContent = point.amount;
    link.appendChild(amount);

    const item = document.createElement("li");
    item.appendChild(link);
    return item;
  }

  #popupHtml(point) {
    const link = document.createElement("a");
    link.href = point.transaction_path;
    link.textContent = point.transaction_name;

    const wrapper = document.createElement("div");
    wrapper.appendChild(link);

    const meta = document.createElement("div");
    meta.textContent = `${point.amount} · ${point.date}`;
    wrapper.appendChild(meta);

    return wrapper;
  }
}
