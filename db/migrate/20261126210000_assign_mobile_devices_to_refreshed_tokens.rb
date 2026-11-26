# Tokens the mobile app's refresh token bought at /oauth/token were saved
# without a device, so signing in again on that device left them working.
#
# A sign-in before this migration may already have missed them, and a token
# refreshed from one through /api/v1/auth/refresh kept no link to its parent,
# so neither the device nor a missed revocation can be worked out reliably.
# Every mobile client token without a device is revoked, which costs those
# sessions one sign-in. Each refreshed token names the one it replaced in
# previous_refresh_token: those links are followed from every device token to
# record the device on its descendants.
class AssignMobileDevicesToRefreshedTokens < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE oauth_access_tokens
      SET revoked_at = CURRENT_TIMESTAMP
      WHERE mobile_device_id IS NULL
        AND revoked_at IS NULL
        AND application_id IN (
          SELECT id FROM oauth_applications
          WHERE name = 'Sure Mobile' AND redirect_uri = 'sureapp://oauth/callback'
        )
    SQL

    execute <<~SQL
      WITH RECURSIVE lineage AS (
        SELECT refresh_token, mobile_device_id
        FROM oauth_access_tokens
        WHERE mobile_device_id IS NOT NULL AND refresh_token IS NOT NULL
        UNION
        SELECT child.refresh_token, lineage.mobile_device_id
        FROM oauth_access_tokens child
        JOIN lineage ON child.previous_refresh_token = lineage.refresh_token
        WHERE child.mobile_device_id IS NULL AND child.refresh_token IS NOT NULL
      )
      UPDATE oauth_access_tokens
      SET mobile_device_id = lineage.mobile_device_id
      FROM lineage
      WHERE oauth_access_tokens.refresh_token = lineage.refresh_token
        AND oauth_access_tokens.mobile_device_id IS NULL
    SQL
  end

  def down
    # Revoked tokens stay revoked and the device ids it assigns are correct.
  end
end
