class AddRequestedConsentValidUntilToEnableBankingItems < ActiveRecord::Migration[8.1]
  def change
    add_column :enable_banking_items, :requested_consent_valid_until, :datetime
  end
end
