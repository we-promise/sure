# Use the Rails cache store (Redis in production) for the framework-level
# Rack session. The application's own user authentication is handled by
# the database-backed Session model (`_session_token`); this session is
# only used by middleware such as OmniAuth during the OIDC callback flow.
#
# Storing it in the cookie (Rails' default) overflows the 4KB limit when
# OmniAuth writes the full auth hash for IdPs that return many group
# claims. See: https://github.com/we-promise/sure/issues/1571
#
# Falls back to the cookie store in environments where the cache is
# `NullStore` (e.g. development without caching, test). NullStore drops
# all writes, which would break multi-step flows like OmniAuth, MFA, and
# mobile SSO that rely on session state surviving across requests.
cache_store_config = Rails.application.config.cache_store
cache_store_type = cache_store_config.is_a?(Array) ? cache_store_config.first : cache_store_config

session_ttl = ENV.fetch("RACK_SESSION_TTL_HOURS", "1").to_i.hours

if cache_store_type == :null_store
  Rails.application.config.session_store :cookie_store,
    key: "_sure_session",
    expire_after: session_ttl,
    httponly: true,
    secure: Rails.env.production?
else
  Rails.application.config.session_store :cache_store,
    key: "_sure_session",
    expire_after: session_ttl,
    httponly: true,
    secure: Rails.env.production?
end
