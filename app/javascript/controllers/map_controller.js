import { Controller } from "@hotwired/stimulus";
import L from "leaflet";
import "leaflet.markercluster";

// Connects to data-controller="map"
export default class extends Controller {
  static targets = ["container", "item"];
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
  // rather than the full (possibly date/account-filtered) result set. Rows
  // are rendered once in ERB; this just shows/hides them by bounds.
  #updateVisibleList() {
    const bounds = this.map.getBounds();
    this.itemTargets.forEach((item) => {
      const inView = bounds.contains([
        Number(item.dataset.lat),
        Number(item.dataset.lng),
      ]);
      item.classList.toggle("hidden", !inView);
    });
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
