# frozen_string_literal: true

class RevolutXAccount < ProviderAccount
  include Encryptable

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :revolut_x_item

  validates :name, :account_id, :account_type, :currency, presence: true

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
