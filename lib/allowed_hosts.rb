# The Host header values this instance answers to, for Rails' DNS-rebinding
# protection.
#
# APP_DOMAIN and ALLOWED_HOSTS are unioned rather than ordered by precedence.
# APP_DOMAIN is already set by many operators for outgoing mail, and those same
# instances are often reached over a LAN address, a Tailscale name or localhost,
# none of which match it. Letting APP_DOMAIN alone define the list turned every
# one of those into a 403.
#
# An empty union leaves config.hosts unset, which means Rails accepts any Host.
# That is the pre-existing behaviour, kept so an upgrade cannot lock an operator
# out of their own instance; the boot warning points at the fix.
module AllowedHosts
  module_function

  def list
    [ ENV["APP_DOMAIN"], *ENV["ALLOWED_HOSTS"].to_s.split(",") ]
      .filter_map { |host| normalize(host) }
      .uniq
  end

  # A Host header is a bare hostname, so drop anything an operator may have
  # pasted around it. The WebAuthn initializer already does the same with
  # APP_DOMAIN, which is where most of these values come from.
  def normalize(host)
    host.to_s
        .strip
        .sub(%r{\Ahttps?://}i, "")
        .split("/").first.to_s
        .split(":").first.to_s
        .downcase
        .presence
  end
end
