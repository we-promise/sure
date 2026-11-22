import { Controller } from "@hotwired/stimulus";
import L from "leaflet";
import "leaflet.markercluster";

// Connects to data-controller="map"
export default class extends Controller {
  static values = { points: Array };

  connect() {
    this.map = L.map(this.element).setView([20, 0], 2);

    L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap contributors",
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
  }

  disconnect() {
    this.map?.remove();
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
