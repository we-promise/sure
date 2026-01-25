# Shared concern for generating content-based hashes for Lunchflow transactions
# Used by both the importer (for deduplication) and processor (for temporary external IDs)
module LunchflowTransactionHash
  extend ActiveSupport::Concern

  private

    # Generate a content-based hash for a transaction
    # This creates a deterministic identifier based on transaction attributes
    # Used for:
    # - Deduplicating blank-ID transactions in the importer
    # - Generating temporary external IDs in the processor
    #
    # @param tx [Hash] Transaction data with indifferent access
    # @return [String] MD5 hash of transaction attributes
    def content_hash_for_transaction(tx)
      attributes = [
        tx[:accountId],
        tx[:amount],
        tx[:currency],
        tx[:date],
        tx[:merchant],
        tx[:description]
      ].compact.join("|")

      Digest::MD5.hexdigest(attributes)
    end
end
