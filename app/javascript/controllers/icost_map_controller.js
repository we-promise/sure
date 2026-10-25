import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["canvas", "record", "latitude", "longitude", "status"];
  static values = { tiles: String, error: String, pick: String };

  async load(event) {
    if (this.map || this.loading) return;
    const button = event.currentTarget;
    this.loading = true;
    try {
      this.leaflet = await import("leaflet");
      if (!this.element.isConnected) return;
      const L = this.leaflet;
      this.map = L.map(this.canvasTarget).setView([20, 0], 2);
      L.tileLayer(this.tilesValue, {
        maxZoom: 19,
        attribution:
          '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      })
        .on("tileerror", () => {
          this.statusTarget.textContent = this.errorValue;
        })
        .addTo(this.map);
      this.layer = L.layerGroup().addTo(this.map);
      if (this.recordTargets.length) {
        this.map.fitBounds(
          this.recordTargets.map((record) => [
            Number(record.dataset.latitude),
            Number(record.dataset.longitude),
          ]),
          { padding: [32, 32], maxZoom: 16 },
        );
      }
      this.map.on("moveend zoomend", () => this.renderMarkers());
      this.map.on("click", ({ latlng }) =>
        this.setCoordinates(latlng.lat, latlng.lng),
      );
      this.renderMarkers();
      this.statusTarget.textContent = this.pickValue;
      button.disabled = true;
    } catch {
      this.map?.remove();
      this.map = null;
      this.statusTarget.textContent = this.errorValue;
    } finally {
      this.loading = false;
    }
  }

  choose(event) {
    const { latitude, longitude } = event.currentTarget.dataset;
    this.setCoordinates(Number(latitude), Number(longitude));
    this.map?.setView([Number(latitude), Number(longitude)], 16);
  }

  setCoordinates(latitude, longitude) {
    if (!this.hasLatitudeTarget) return;
    this.latitudeTarget.value = latitude.toFixed(6);
    this.longitudeTarget.value = longitude.toFixed(6);
    if (this.map) {
      this.selection?.remove();
      this.selection = this.leaflet
        .circleMarker([latitude, longitude], { radius: 12 })
        .addTo(this.map);
    }
  }

  renderMarkers() {
    this.layer.clearLayers();
    const groups = new Map();
    for (const record of this.recordTargets) {
      const latlng = [
        Number(record.dataset.latitude),
        Number(record.dataset.longitude),
      ];
      const point = this.map.project(latlng);
      const key = `${Math.floor(point.x / 48)}:${Math.floor(point.y / 48)}`;
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(record);
    }
    for (const records of groups.values()) {
      const first = records[0];
      const pin = first.content
        .querySelector("[data-icost-pin]")
        .cloneNode(true);
      if (records.length > 1) {
        pin.querySelector("[data-pin-icon]").remove();
        const count = pin.querySelector("[data-pin-count]");
        count.textContent = records.length;
        count.classList.remove("hidden");
      }
      const popup = document.createElement("div");
      popup.className = "space-y-3 max-h-64 overflow-y-auto";
      for (const record of records)
        popup.append(
          record.content.querySelector("[data-icost-popup]").cloneNode(true),
        );
      const marker = this.leaflet
        .marker(
          [Number(first.dataset.latitude), Number(first.dataset.longitude)],
          {
            icon: this.leaflet.divIcon({
              html: pin,
              className: "",
              iconSize: [40, 40],
              iconAnchor: [20, 40],
            }),
            title: `${first.dataset.label} (${records.length})`,
          },
        )
        .addTo(this.layer)
        .bindPopup(popup);
      if (records.length > 1)
        marker.on("dblclick", () =>
          this.map.setView(marker.getLatLng(), this.map.getZoom() + 2),
        );
    }
  }

  disconnect() {
    this.map?.remove();
    this.map = null;
  }
}
