# frozen_string_literal: true

class CoinspotAccount < ApplicationRecord
  include Encryptable

  FIAT_CURRENCIES = %w[AUD USD EUR GBP CAD CHF JPY NZD SGD HKD].freeze
  STABLECOINS = %w[USDT USDC DAI PYUSD USDP TUSD USDG].freeze

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :coinspot_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :account_id, :account_type, :currency, presence: true

  def current_account
    account
  end

  def ensure_account_provider!(target_account = nil)
    acct = target_account || current_account
    return nil unless acct

    AccountProvider
      .find_or_initialize_by(provider_type: "CoinspotAccount", provider_id: id)
      .tap do |ap|
        ap.account = acct
        ap.save!
      end
  rescue StandardError => e
    Rails.logger.warn("CoinspotAccount #{id}: failed to link account provider - #{e.class}: #{e.message}")
    nil
  end
end
