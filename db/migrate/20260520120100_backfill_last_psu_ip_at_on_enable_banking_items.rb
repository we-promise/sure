# frozen_string_literal: true

class BackfillLastPsuIpAtOnEnableBankingItems < ActiveRecord::Migration[7.2]
  def up
    say_with_time "Backfilling last_psu_ip_at from updated_at for existing PSU IPs" do
      execute <<-SQL.squish
        UPDATE enable_banking_items
        SET last_psu_ip_at = updated_at
        WHERE last_psu_ip IS NOT NULL
          AND last_psu_ip_at IS NULL
      SQL
    end
  end

  def down
    execute <<-SQL.squish
      UPDATE enable_banking_items
      SET last_psu_ip_at = NULL
      WHERE last_psu_ip IS NOT NULL
        AND last_psu_ip_at = updated_at
    SQL
  end
end
