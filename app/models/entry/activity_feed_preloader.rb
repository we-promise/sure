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
        associations: [
          :merchant,
          :category,
          # Transfer#categorizable? / #payment? walk to_account via
          # inflow_transaction.entry.account. Flat transfer includes alone
          # still N+1 that triad during activity-row render.
          {
            transfer_as_inflow: {
              inflow_transaction: { entry: :account }
            }
          },
          {
            transfer_as_outflow: {
              inflow_transaction: { entry: :account }
            }
          }
        ]
      ).call

      ActiveRecord::Associations::Preloader.new(records: trades, associations: [ :security ]).call
    end
end
