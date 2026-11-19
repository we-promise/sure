# frozen_string_literal: true

class RevolutXAccount < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :revolut_x_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account

  validates :name, :account_id, :account_type, :currency, presence: true

  def current_account
    account
  end

  # An asset left out of the account's value because nothing prices it.
  def report_unvalued_asset(symbol, source:)
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "warn",
      message: "Revolut X asset #{symbol} not valued: no price or usable ticker",
      source: source,
      provider_key: "revolut_x",
      family: revolut_x_item.family,
      account_provider: account_provider,
      metadata: { revolut_x_item_id: revolut_x_item_id, symbol: symbol }
    )
  end
end
