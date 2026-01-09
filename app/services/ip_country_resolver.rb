require "ipaddr"
require "net/http"

class IpCountryResolver
  LOOKUP_URL = "https://ipapi.co/%{ip}/country/"

  def self.call(ip_address)
    return if ip_address.blank?
    return if private_ip?(ip_address)

    uri = URI.parse(LOOKUP_URL % { ip: ip_address })
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 2
    http.read_timeout = 2

    response = http.get(uri.request_uri)
    return unless response.is_a?(Net::HTTPSuccess)

    country_code = response.body.to_s.strip.upcase
    return if country_code.length != 2

    country_code
  rescue StandardError => e
    Rails.logger.info("IpCountryResolver failed for #{ip_address}: #{e.class}")
    nil
  end

  def self.private_ip?(ip_address)
    ip = IPAddr.new(ip_address)
    ip.private? || ip.loopback? || ip.link_local?
  rescue IPAddr::InvalidAddressError
    true
  end
end
