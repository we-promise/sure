# frozen_string_literal: true

class AddConsentExpiresAtToGocardlessItems < ActiveRecord::Migration[8.1]
  def change
    add_column :gocardless_items, :consent_expires_at, :datetime
  end
end
