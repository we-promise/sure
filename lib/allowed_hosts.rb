# frozen_string_literal: true

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
    parse.fetch(:allowed)
  end

  # Entries that were thrown away, so the caller can say so at boot rather than
  # leaving an operator to work out why their host still gets a 403.
  def rejected
    parse.fetch(:rejected)
  end

  def parse
    allowed = []
    rejected = []

    raw_entries.each do |entry|
      host = normalize(entry)
      host ? allowed << host : rejected << entry
    end

    { allowed: allowed.uniq, rejected: rejected.uniq }
  end

  def raw_entries
    [ ENV["APP_DOMAIN"], *ENV["ALLOWED_HOSTS"].to_s.split(",") ]
      .map { |entry| entry.to_s.strip }
      .reject(&:empty?)
  end

  # A Host header is a bare hostname, so drop anything an operator may have
  # pasted around it. The WebAuthn initializer already does the same with
  # APP_DOMAIN, which is where most of these values come from.
  def normalize(entry)
    value = entry.to_s.strip.sub(%r{\Ahttps?://}i, "").split("/").first.to_s
    return nil if value.empty?

    # Rails reads a leading dot as "any subdomain of", so ".example.com" would
    # quietly turn an allow-list into a wildcard. Hosts are listed one by one
    # here, so this is refused rather than silently honoured.
    return nil if value.start_with?(".")

    # An IPv6 Host header is bracketed, and the brackets are part of what Rails
    # matches, so they stay. Only the port comes off.
    return value[/\A\[[^\]]+\]/]&.downcase if value.start_with?("[")

    # A bare IPv6 address has no port to strip, and needs bracketing to match
    # the Host header a browser actually sends.
    return "[#{value.downcase}]" if value.count(":") > 1

    value.split(":").first.to_s.downcase.presence
  end
end
