# Tokens the mobile app's refresh token bought at /oauth/token were saved
# without a device, so signing in again on that device left them working.
# Each one names the token it replaced in previous_refresh_token: follow those
# links from every device token and give its descendants the same device.
class AssignMobileDevicesToRefreshedTokens < ActiveRecord::Migration[8.1]
  def up
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
    # The device ids it assigns are correct, so there is nothing to undo.
  end
end
