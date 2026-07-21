class Entry::ActivityFeedPreloader
  def initialize(entries)
    @entries = Array(entries)
  end

  def preload
    preload_entry_associations
    preload_entryable_associations
    entries
  end

  private
    attr_reader :entries

    def entryables
      @entryables ||= entries.filter_map(&:entryable)
    end

    def transactions
      @transactions ||= entryables.grep(Transaction)
    end

    def trades
      @trades ||= entryables.grep(Trade)
    end

    def preload_entry_associations
      ActiveRecord::Associations::Preloader.new(records: entries, associations: [ :account ]).call
    end

    def preload_entryable_associations
      ActiveRecord::Associations::Preloader.new(
        records: transactions,
        associations: [ :merchant, :category, :transfer_as_inflow, :transfer_as_outflow ]
      ).call

      ActiveRecord::Associations::Preloader.new(records: trades, associations: [ :security ]).call
    end
end
