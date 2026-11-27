# What an IP address is, as opposed to what a caller may do with it.
# Provider::Simplefin decides which hosts it may connect to, and that depends
# on the app mode; EnableBankingItem decides whether a browser's address is
# one a bank will accept. Both need an IPv6 literal that carries an IPv4
# address read as that address, so the unwrapping lives here once.
module NetworkAddress
  NAT64_NETWORK = IPAddr.new("64:ff9b::/96")
  IPV4_TRANSLATED_NETWORK = IPAddr.new("::ffff:0:0:0/96")
  SIX_TO_FOUR_NETWORK = IPAddr.new("2002::/16")
  IPV4_COMPATIBLE_NETWORK = IPAddr.new("::/96")

  # IANA special-purpose ranges that are not globally reachable, beyond what
  # IPAddr#private?, #loopback? and #link_local? already answer.
  NON_PUBLIC_NETWORKS = %w[
    0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 192.0.2.0/24 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ::/128 64:ff9b:1::/48 100::/64 2001:2::/48 2001:db8::/32 ff00::/8
  ].map { |range| IPAddr.new(range) }.freeze

  module_function

  # IPv4-mapped, IPv4-compatible, NAT64 and 6to4 addresses reach the IPv4
  # address they carry, so they are checked as that address.
  def embedded_ipv4(ip)
    return ip unless ip.ipv6?
    return ip.native if ip.ipv4_mapped?

    if NAT64_NETWORK.include?(ip) || IPV4_TRANSLATED_NETWORK.include?(ip) || (IPV4_COMPATIBLE_NETWORK.include?(ip) && ip.to_i > 1)
      IPAddr.new(ip.to_i & 0xffff_ffff, Socket::AF_INET)
    elsif SIX_TO_FOUR_NETWORK.include?(ip)
      IPAddr.new((ip.to_i >> 80) & 0xffff_ffff, Socket::AF_INET)
    else
      ip
    end
  end

  # True for an address that is globally reachable. Anything unparseable is
  # not.
  def public?(address)
    ip = embedded_ipv4(IPAddr.new(address.to_s))
    !(ip.private? || ip.loopback? || ip.link_local? || NON_PUBLIC_NETWORKS.any? { |network| network.include?(ip) })
  rescue IPAddr::Error
    false
  end
end
