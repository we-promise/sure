# Registers platform-wide action-required notices. See MigrationNotice for
# the registry contract. Each entry needs a matching locale block under
# config/locales/views/migration_notices/<locale>.yml at
# migration_notices.<key>.{title, body_html, copy, copied, dismiss,
# copyable_label?}.
#
# Adding a new notice when the next migration needs operator action:
#   1. MigrationNotice.register here with a unique key + scope + condition.
#   2. Add the locale block.
#   3. (Optional) wire `<%= render_migration_notices(scope: :your_scope) %>`
#      into a view if it's not already covered by an existing render.

Rails.application.config.after_initialize do
  MigrationNotice.register(
    key:        :plaid_oauth_redirect_uri,
    scope:      :providers,
    condition:  ->(family) { family.provider_connections.exists?(provider_key: "plaid") },
    copyable_value: ->(view) {
      view.provider_auth_url(provider_key: "plaid", host: view.configured_host)
    }
  )
end
