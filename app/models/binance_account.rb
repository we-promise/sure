# frozen_string_literal: true

class BinanceAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :binance_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  def current_account
    account
  end

  def ensure_account_provider!(linked_account = nil)
    acct = linked_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: "BinanceAccount", provider_id: id)
      .tap do |ap|
        ap.account = acct
        ap.save!
      end
  rescue => e
    Rails.logger.warn("Binance provider link failed for #{id}: #{e.class} - #{e.message}")
    nil
  end

  private

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency '#{currency_value}' for BinanceAccount #{id}, defaulting to USD")
    end
end
