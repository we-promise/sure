class OauthCallbacksController < ApplicationController
  include ProviderAuthFlowSession

  before_action :require_admin!

  # POST /provider_connections/:provider_key/auth/start — initiates OAuth.
  def new
    config = Current.family.provider_family_configs.find_by!(provider_key: params[:provider_key])
    # Build redirect_uri using the configured host rather than the request host.
    # OAuth servers require the EXACT redirect_uri at exchange — and a Host-
    # header-injection on a misconfigured deployment would otherwise seed an
    # attacker-controlled redirect_uri here. Falls back to request-derived URL
    # only if nothing is configured (dev defaults).
    redirect_uri = provider_auth_url(provider_key: config.provider_key, host: configured_host)

    adapter_class = Provider::ConnectionRegistry.adapter_for(config.provider_key)
    sandbox = adapter_class.sandbox_for(config)
    flow_id = SecureRandom.hex(16)
    write_flow!(flow_id, {
      "provider_key"              => config.provider_key,
      "provider_family_config_id" => config.id,
      "redirect_uri"              => redirect_uri,
      "psu_ip"                    => public_client_ip,
      "sandbox"                   => sandbox,
      "created_at"                => Time.current.to_i
    })

    # config_for returns adapter.new(nil) — the stateless helper instance used
    # by authorize_url / scopes / token_client (no @connection required).
    adapter = Provider::ConnectionRegistry.config_for(config.provider_key)
    auth_url = adapter.authorize_url(
      client_id:    config.client_id,
      redirect_uri: redirect_uri,
      state:        flow_id,
      scope:        adapter.scopes,
      sandbox:      sandbox
    )
    redirect_to auth_url, allow_other_host: true
  end

  private

    # IPv4 carrier-grade NAT range (RFC 6598) — IPAddr#private? misses these.
    CGNAT_RANGE = IPAddr.new("100.64.0.0/10").freeze
    private_constant :CGNAT_RANGE

    # Filters out IPs that aren't public-routable. PSU IP is forwarded to
    # TrueLayer; leaking an internal/CGNAT/cloud-metadata address is a privacy
    # issue. IPAddr#private? alone misses link-local (incl. cloud metadata
    # 169.254.169.254) and CGNAT (100.64.0.0/10).
    def public_client_ip
      ip = request.remote_ip
      return nil if ip.blank?
      addr = IPAddr.new(ip)
      return nil if addr.private? || addr.loopback? || addr.link_local?
      return nil if addr.ipv4? && CGNAT_RANGE.include?(addr)
      ip
    rescue IPAddr::InvalidAddressError
      nil
    end
end
