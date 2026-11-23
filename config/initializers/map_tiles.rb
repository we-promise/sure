Rails.application.configure do
  # The marker icons are vendored so a self-hosted instance needs no CDN; map
  # tiles are the same kind of dependency. Point these at your own tile server
  # to cut the last outbound call the map makes.
  config.x.map_tile_url = ENV.fetch("MAP_TILE_URL", "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
  config.x.map_tile_attribution = ENV.fetch("MAP_TILE_ATTRIBUTION", "&copy; OpenStreetMap contributors")
end
