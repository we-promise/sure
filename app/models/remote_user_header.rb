# Rules for reverse-proxy header authentication that more than one layer
# enforces. The Authentication concern and the Rack::Attack throttle run at
# different points in the request, and each must reach the same answer.
module RemoteUserHeader
  class << self
    # Raises IPAddr::Error when remote_addr is missing or unparseable, so each
    # caller decides how to fail closed.
    def trusted_peer?(remote_addr)
      peer_ip = IPAddr.new(remote_addr)
      # IPAddr#include? never crosses address families, so an IPv4-mapped IPv6
      # peer (::ffff:127.0.0.1 — routine for a dual-stack nginx or Docker
      # front-end) matches neither an IPv4 nor an IPv6 range. Compare the
      # native IPv4 form instead.
      peer_ip = peer_ip.native if peer_ip.ipv4_mapped?

      config.remote_user_trusted_proxies.any? { |range| range.include?(peer_ip) }
    end

    private
      def config
        Rails.application.config
      end
  end
end
