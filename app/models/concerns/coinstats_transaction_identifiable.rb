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

      # Fallback: generate ID from multiple fields to reduce collision risk.
      # Include as many distinguishing fields as possible since transactions
      # with same date/type/amount are common (DCA, recurring purchases, batch trades).
      fallback_id = build_fallback_transaction_id(tx)
      return fallback_id if fallback_id.present?

      nil
    end

    # Builds a fallback transaction ID from available fields.
    # Uses a hash digest of combined fields to handle varying field availability
    # while maintaining uniqueness across similar transactions.
    # @param tx [HashWithIndifferentAccess] Transaction data
    # @return [String, nil] Generated fallback ID or nil if insufficient data
    def build_fallback_transaction_id(tx)
      date = tx[:date]
      type = tx[:type]
      amount = tx.dig(:coinData, :count)

      # Require minimum fields for a valid fallback
      return nil unless date.present? && type.present? && amount.present?

      # Collect additional distinguishing fields.
      # Only use stable transaction data—avoid market-dependent values
      # (currentValue, totalWorth, profit) that can change between API calls.
      components = [
        date,
        type,
        amount,
        tx.dig(:coinData, :symbol),
        tx.dig(:fee, :count),
        tx.dig(:fee, :coin, :symbol),
        tx.dig(:transactions, 0, :action),
        tx.dig(:transactions, 0, :items, 0, :coin, :id),
        tx.dig(:transactions, 0, :items, 0, :count)
      ].compact

      # Generate a hash digest for a fixed-length, collision-resistant ID
      content = components.join("|")
      "fallback_#{Digest::SHA256.hexdigest(content)[0, 16]}"
    end
end
