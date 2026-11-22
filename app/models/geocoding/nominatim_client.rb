require "net/http"
require "json"

class Geocoding::NominatimClient
  BASE_URL = "https://nominatim.openstreetmap.org"
  USER_AGENT = "Sure (self-hosted personal finance app; https://github.com/we-promise/sure)"
  CACHE_EXPIRY = 1.day

  Result = Struct.new(:lat, :lng, :display_name, keyword_init: true)

  class RequestFailed < StandardError; end

  # Forward geocoding: free-text query -> up to 5 candidate places.
  def search(query)
    return [] if query.blank?

    Rails.cache.fetch(cache_key("search", query), expires_in: CACHE_EXPIRY) do
      response = get("/search", q: query, format: "json", limit: 5)
      Array(response).map { |place| to_result(place) }
    end
  end

  # Reverse geocoding: coordinates -> the single best display name.
  def reverse(lat, lng)
    Rails.cache.fetch(cache_key("reverse", "#{lat},#{lng}"), expires_in: CACHE_EXPIRY) do
      response = get("/reverse", lat: lat, lon: lng, format: "json")
      response.present? ? to_result(response) : nil
    end
  end

  private

    def to_result(place)
      Result.new(
        lat: place["lat"].to_f,
        lng: place["lon"].to_f,
        display_name: place["display_name"]
      )
    end

    def cache_key(action, value)
      "geocoding/nominatim/#{action}/#{value}"
    end

    def get(path, params)
      uri = URI("#{BASE_URL}#{path}")
      uri.query = URI.encode_www_form(params)

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = USER_AGENT

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

      raise RequestFailed, "Nominatim returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
end
