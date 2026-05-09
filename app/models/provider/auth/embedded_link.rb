# Auth lifecycle for providers that use an embedded link widget — the user
# completes auth in a vendor-hosted modal embedded in our page (no redirect),
# the modal's onSuccess callback returns an opaque public_token, and the
# server exchanges it once for a long-lived access_token.
#
# Concrete instances of this pattern: Plaid Link, MX Connect Widget,
# Yodlee FastLink, Akoya Connect.
#
# Differs from OAuth2 in three ways:
#   - No redirect grant — the public_token arrives via XHR, not a callback URL.
#   - access_token does not expire and has no refresh_token.
#   - requires_update transitions are signalled by upstream webhooks
#     (e.g. Plaid's ITEM_LOGIN_REQUIRED), not by failed token refresh.
#
# Callers (controllers) do the actual token exchange via the adapter's HTTP
# client, since the request format is provider-specific. This class manages
# the persisted credential lifecycle.
class Provider::Auth::EmbeddedLink
  def initialize(connection)
    @connection = connection
  end

  # ---- Read-only ---------------------------------------------------------

  def fresh_access_token
    @connection.credentials["access_token"]
  end

  # ---- Mutators ----------------------------------------------------------

  # Persists the access_token returned by the upstream public_token exchange.
  # Token does not expire, so no refresh metadata is written.
  def store_access_token(access_token)
    @connection.update!(
      credentials: @connection.credentials.merge("access_token" => access_token)
    )
  end

  # Webhook-driven transition. Called by webhook handlers when the upstream
  # signals the user must re-auth (Plaid: ITEM_LOGIN_REQUIRED / PENDING_EXPIRATION).
  def mark_requires_update!(reason: "reauth_required")
    @connection.update!(status: :requires_update, sync_error: reason)
  end
end
