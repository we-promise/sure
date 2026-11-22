class LocationSearchesController < ApplicationController
  before_action :require_preview_features!

  def index
    results = Geocoding::NominatimClient.new.search(params[:q])

    render json: results.map { |r| { lat: r.lat, lng: r.lng, display_name: r.display_name } }
  rescue Geocoding::NominatimClient::RequestFailed, Net::OpenTimeout, Net::ReadTimeout
    render json: [], status: :service_unavailable
  end
end
