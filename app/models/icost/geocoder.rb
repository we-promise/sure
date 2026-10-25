require "digest"

module Icost
  # Explicit place searches only. No upload, transaction, amount or note is sent.
  class Geocoder
    Error = Class.new(StandardError)
    RateLimited = Class.new(Error)

    def initialize(cache: Rails.cache)
      @cache = cache
    end

    def search(query)
      query = query.to_s.strip
      raise Error unless query.length.between?(3, 160)
      endpoint = ENV.fetch("ICOST_GEOCODING_URL", "https://nominatim.openstreetmap.org/search")
      key = "icost:geocoding:#{Digest::SHA256.hexdigest("#{endpoint}:#{query.downcase}")}"
      cached = @cache.read(key)
      return cached unless cached.nil?
      # Shared Redis in production: one request per application, across users
      # and workers. Fail closed if the cache cannot acquire the rate limit.
      raise RateLimited unless @cache.write("icost:geocoding:rate", true, unless_exist: true, expires_in: 1.1.seconds)

      response = Faraday.get(endpoint, { q: query, format: "jsonv2", limit: 5 },
        { "User-Agent" => "Sure-iCost/1.0 (+https://github.com/we-promise/sure)", "Accept" => "application/json" }) do |request|
        request.options.timeout = 8
        request.options.open_timeout = 3
      end
      raise Error unless response.success? && response.body.bytesize <= 1.megabyte
      data = JSON.parse(response.body)
      raise Error unless data.is_a?(Array)
      results = data.first(5).filter_map do |item|
        next unless item.is_a?(Hash)
        coordinates = IcostRecord.valid_coordinates(item["lat"], item["lon"])
        next unless coordinates
        { "latitude" => coordinates.first, "longitude" => coordinates.last, "name" => item["display_name"].to_s.truncate(300) }
      end
      @cache.write(key, results, expires_in: 30.days)
      results
    rescue Faraday::Error, JSON::ParserError
      raise Error
    end
  end
end
