class MarkLegacySnaptradeItemsRequiringUpdate < ActiveRecord::Migration[7.2]
  # Data-only: legacy items (connected via client_id/consumer_key, no OAuth
  # tokens) can no longer sync and must be reconnected via the OAuth flow.
  def up
    execute <<~SQL
      UPDATE snaptrade_items
      SET status = 'requires_update'
      WHERE (oauth_access_token IS NULL OR oauth_access_token = '')
        AND scheduled_for_deletion = FALSE
    SQL
  end

  def down
    # Irreversible data migration; no-op
  end
end
