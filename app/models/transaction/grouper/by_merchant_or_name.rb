class Transaction::Grouper::ByMerchantOrName < Transaction::Grouper
  def self.call(family, limit: 20, offset: 0)
    new(family).call(limit: limit, offset: offset)
  end

  def initialize(family)
    @family = family
  end

  def call(limit: 20, offset: 0)
    uncategorized_entries
      .group_by { |entry| grouping_key_for(entry) }
      .map { |key, entries| build_group(key, entries) }
      .sort_by { |g| [ -g.entries.size, g.display_name ] }
      .drop(offset)
      .first(limit)
  end

  private

    attr_reader :family

    def uncategorized_entries
      family.entries
            .joins(:account)
            .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
            .where(accounts: { status: %w[draft active] })
            .where(transactions: { category_id: nil })
            .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
            .where(entries: { excluded: false })
            .includes(entryable: :merchant)
            .order(entries: { date: :desc })
    end

    def grouping_key_for(entry)
      entry.entryable.merchant&.name.presence || entry.name
    end

    def build_group(key, entries)
      merchant = entries.find { |e| e.entryable.merchant.present? }&.entryable&.merchant

      Transaction::Grouper::Group.new(
        grouping_key: key,
        display_name: key,
        entries: entries,
        merchant: merchant
      )
    end
end
