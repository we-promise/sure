# frozen_string_literal: true

# Shared logic for extracting unique transaction IDs from CoinStats API responses.
# Different blockchains return transaction IDs in different locations:
# - Ethereum/EVM: hash.id (transaction hash)
# - Bitcoin/UTXO: transactions[0].items[0].id
module CoinstatsTransactionIdentifiable
  extend ActiveSupport::Concern

  private

    # Extracts a unique transaction ID from CoinStats transaction data.
    # Handles different blockchain formats and generates fallback IDs.
    # @param transaction_data [Hash] Raw transaction data from API
    # @return [String, nil] Unique transaction identifier or nil
    def extract_coinstats_transaction_id(transaction_data)
      tx = transaction_data.is_a?(Hash) ? transaction_data.with_indifferent_access : {}

      # Try hash.id first (Ethereum/EVM chains)
      hash_id = tx.dig(:hash, :id)
      return hash_id if hash_id.present?

      # Try transactions[0].items[0].id (Bitcoin/UTXO chains)
      item_id = tx.dig(:transactions, 0, :items, 0, :id)
      return item_id if item_id.present?

      # Fallback: generate ID from date + type + amount
      date = tx[:date]
      type = tx[:type]
      amount = tx.dig(:coinData, :count)
      return "#{date}_#{type}_#{amount}" if date.present? && type.present? && amount.present?

      nil
    end
end
