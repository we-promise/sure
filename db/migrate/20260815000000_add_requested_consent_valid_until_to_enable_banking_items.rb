class AddRequestedConsentValidUntilToEnableBankingItems < ActiveRecord::Migration[7.2]
  def change
    add_column :enable_banking_items, :requested_consent_valid_until, :datetime
  end
end
