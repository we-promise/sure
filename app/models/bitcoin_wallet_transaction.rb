# frozen_string_literal: true

class BitcoinWalletTransaction < ApplicationRecord
  belongs_to :bitcoin_wallet_account
  validates :txid, format: { with: /\A[0-9a-f]{64}\z/ }, uniqueness: { scope: :bitcoin_wallet_account_id }
  validates :amount_sats, numericality: { only_integer: true }

  # Convert the signed owned movement from integer satoshis to decimal BTC.
  def quantity
    amount_sats.to_d / 100_000_000
  end
end
