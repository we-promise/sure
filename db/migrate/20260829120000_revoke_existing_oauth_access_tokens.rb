# H2's TTL fix (access_token_expires_in: 1.year -> 2.hours, see the doorkeeper
# initializer) only governs newly minted tokens. Every access token issued
# before this deploy already has its own 1-year `expires_in` baked into its
# row at creation time, so a token leaked under the old policy would keep
# working for up to a year even after this deploy ships. Revoking every live
# standard-flow token now forces those clients back through re-authorization
# under the new TTL.
#
# Mobile app tokens are excluded: they're minted through a separate path
# (MobileDevice#issue_token!) that already hardcodes a 30-day expiry
# independent of this setting, so they aren't part of the gap this closes.
class RevokeExistingOauthAccessTokens < ActiveRecord::Migration[7.2]
  def up
    execute <<~SQL
      UPDATE oauth_access_tokens
      SET revoked_at = NOW()
      WHERE revoked_at IS NULL
        AND mobile_device_id IS NULL
    SQL
  end

  # The revoked tokens were live under a policy this deploy intentionally
  # retires; there's nothing correct to restore them to.
  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
