# frozen_string_literal: true

# The Host header values this instance answers to, for Rails' DNS-rebinding
# protection.
#
# Only ALLOWED_HOSTS turns the check on. Once it lists a usable host,
# APP_DOMAIN joins the list, so the public name does not have to be written
# twice. APP_DOMAIN alone turns nothing on: the SMTP guide and the Helm chart
# set it for mail, and those same instances are often reached over a LAN
# address, a Tailscale name, a tunnel or Pipelock, none of which match it.
# Letting it switch the check on would turn all of those into 403s on upgrade.
#
# An empty list leaves config.hosts unset, which means Rails accepts any Host.
# That is the pre-existing behaviour, kept so an upgrade cannot lock an operator
# out of their own instance; the warning logged when the web server starts
# points at the fix.
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

  # Probes hit /up over the pod IP or localhost, neither of which matches a
  # configured host, so without this exclusion every liveness and readiness
  # check starts failing with a 403 the moment the list is set.
  def host_authorization
    { exclude: ->(request) { request.path == "/up" } }
  end

  # Registered as a server block, which Rails runs from the load_server call in
  # config.ru, so it is logged once when the web server boots. after_initialize
  # also runs for every rails runner, console, rake task and Sidekiq worker,
  # which filled self-hosters' cron output and worker logs with it.
  def warn_unprotected_on_server_boot(app)
    app.server do
      Rails.logger.warn("[SECURITY] ALLOWED_HOSTS lists no usable host, so DNS rebinding protection is off")
    end
  end

  def parse
    allowed, rejected = partition(ENV["ALLOWED_HOSTS"].to_s.split(","))
    return { allowed: [], rejected: rejected } if allowed.empty?

    app_allowed, app_rejected = partition([ ENV["APP_DOMAIN"] ])
    { allowed: (app_allowed + allowed).uniq, rejected: (app_rejected + rejected).uniq }
  end

  # Splits raw entries into usable hosts and the entries that were refused,
  # skipping blanks.
  def partition(entries)
    allowed = []
    rejected = []

    entries.map { |entry| entry.to_s.strip }.reject(&:empty?).each do |entry|
      host = normalize(entry)
      host ? allowed << host : rejected << entry
    end

    [ allowed.uniq, rejected.uniq ]
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
