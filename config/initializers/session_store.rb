# Use the Rails cache store (Redis in production) for the framework-level
# Rack session. The application's own user authentication is handled by
# the database-backed Session model (`_session_token`); this session is
# only used by middleware such as OmniAuth during the OIDC callback flow.
#
# Storing it in the cookie (Rails' default) overflows the 4KB limit when
# OmniAuth writes the full auth hash for IdPs that return many group
# claims. See: https://github.com/we-promise/sure/issues/1571
Rails.application.config.session_store :cache_store,
  key: "_sure_session",
  expire_after: 1.hour,
  httponly: true,
  secure: Rails.env.production?
