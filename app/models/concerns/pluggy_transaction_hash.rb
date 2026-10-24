# Shared concern for generating content-based hashes for Pluggy transactions
# Used by both the importer (for deduplication) and the transactions processor
# (for generating stable external IDs).
#
# Mirrors LunchflowTransactionHash, but keys off Pluggy's `currencyCode`
# (with `currency` fallback) and the upstream Pluggy `id`.
module PluggyTransactionHash
  extend ActiveSupport::Concern

  private

    # Generate a content-based hash for a Pluggy transaction.
    #
    # @param tx [Hash] transaction data (indifferent or string-keyed)
    # @return [String] MD5 of id|amount|currency|date|merchant|description
    def content_hash_for_transaction(tx)
      attributes = [
        tx[:id] || tx["id"],
        tx[:amount] || tx["amount"],
        tx[:currencyCode] || tx["currencyCode"] || tx[:currency] || tx["currency"],
        tx[:date] || tx["date"],
        tx[:merchant] || tx["merchant"],
        tx[:description] || tx["description"]
      ].compact.join("|")

      Digest::MD5.hexdigest(attributes)
    end
end
