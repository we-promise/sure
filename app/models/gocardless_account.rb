class GocardlessAccount < ApplicationRecord
  include CurrencyNormalizable

  belongs_to :gocardless_item

  # Association through account_providers for linking to internal accounts
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, presence: true

  scope :active,   -> { where(skipped: false) }
  scope :skipped,  -> { where(skipped: true) }
  scope :linked,   -> { joins(:account_provider) }
  scope :unlinked, -> { active.left_joins(:account_provider).where(account_providers: { id: nil }) }

  # Helper to get account using account_providers system
  def current_account
    account
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for Gocardless account #{id} — GoCardless API should always return a valid ISO code; falling back to existing account currency")
    end
end
