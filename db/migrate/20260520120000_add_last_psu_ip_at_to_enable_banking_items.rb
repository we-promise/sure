# frozen_string_literal: true

class AddLastPsuIpAtToEnableBankingItems < ActiveRecord::Migration[7.2]
  def change
    add_column :enable_banking_items, :last_psu_ip_at, :datetime
  end
end
