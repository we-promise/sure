module EnableBankingItem::Provided
  extend ActiveSupport::Concern

  # Carrier-grade NAT (RFC 6598), which Tailscale also uses. IPAddr#private?
  # does not cover it.
  SHARED_ADDRESS_SPACE = IPAddr.new("100.64.0.0/10")

  def enable_banking_provider
    return nil unless credentials_configured?

    Provider::EnableBanking.new(
      application_id: application_id,
      client_certificate: client_certificate
    )
  end

  # Build PSU context headers for data endpoint calls.
  # The Enable Banking API spec mandates: "either all required PSU headers or none".
  # We can only provide Psu-Ip-Address (from last_psu_ip stored at request time).
  # If the ASPSP requires other PSU headers we cannot satisfy server-side, we send none
  # to avoid a PSU_HEADER_NOT_PROVIDED error for partially-supplied headers.
  def build_psu_headers
    return {} if aspsp_required_psu_headers.blank?

    required = aspsp_required_psu_headers.map(&:downcase)

    # Only attempt to satisfy the headers if the only required one is Psu-Ip-Address
    # (the one we can populate from stored data)
    satisfiable = required.all? { |h| h == "psu-ip-address" }
    return {} unless satisfiable && public_psu_ip.present?

    { "Psu-Ip-Address" => public_psu_ip }
  end

  private
    # last_psu_ip is the browser's address as Rails saw it. On a self-hosted
    # instance reached over a LAN or VPN that is a private address, which
    # banks reject as an invalid PSU IP, so only a public one is sent.
    def public_psu_ip
      ip = IPAddr.new(last_psu_ip.to_s).native
      return nil if ip.private? || ip.loopback? || ip.link_local? || ip.to_i.zero? || SHARED_ADDRESS_SPACE.include?(ip)

      last_psu_ip
    rescue IPAddr::Error
      nil
    end
end
