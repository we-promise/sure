class PwaController < ApplicationController
  skip_authentication

  def manifest
    # Force JSON format to avoid MissingTemplate errors when browsers request /manifest
    # with HTML Accept headers (Safari Mobile does this for PWA manifest discovery)
    render "pwa/manifest", formats: [:json], content_type: "application/manifest+json"
  end

  def service_worker
    # Explicitly render JS template to avoid format negotiation issues
    render "pwa/service-worker", content_type: "application/javascript"
  end
  # Renders app/views/pwa/service-worker.js with content type application/javascript
end
