class Transaction::Grouper
  Group = Data.define(:grouping_key, :display_name, :entries, :merchant, :transaction_type)

  # Returns the active grouping strategy class.
  # Change this method to swap algorithms without touching the wizard.
  def self.strategy
    Transaction::Grouper::ByMerchantOrName
  end

  # @param entries [ActiveRecord::Relation] pre-scoped entries to group (caller controls authorization)
  # @param limit [Integer] max number of groups to return
  # @param offset [Integer] number of groups to skip (for pagination)
  # @return [Array<Group>]
  def self.call(entries, limit: 20, offset: 0)
    raise NotImplementedError, "#{name} must implement .call"
  end
end
