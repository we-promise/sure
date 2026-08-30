# Finds the duplicate merchant-side (MCRD) card transactions that were imported
# before PR #3274 landed and are still in the database.
#
# Identification is exact, not heuristic. bank_transaction_code is never read --
# it is not persisted on the transaction (EnableBankingEntry::Processor#extra
# writes only fx_*, merchant_category_code and pending). Instead this relies on
# what #3274 leaves behind: when its filter drops the stored merchant-side rows
# from raw_transactions_payload, the entries they created are left pointing at
# external_ids that are no longer in the snapshot.
#
# Orphanhood alone is not enough -- see the two pending scenarios in the tests.
class EnableBankingAccount::CardTwinCandidates
  include Enumerable

  Candidate = Struct.new(:entry, :survivor, keyword_init: true)

  def initialize(enable_banking_account)
    @enable_banking_account = enable_banking_account
  end

  def to_a
    @to_a ||= build
  end

  def each(&block) = to_a.each(&block)

  delegate :size, :any?, :empty?, to: :to_a

  private
    attr_reader :enable_banking_account

    def account
      @account ||= enable_banking_account.current_account
    end

    def snapshot_external_ids
      @snapshot_external_ids ||= Array(enable_banking_account.raw_transactions_payload)
        .filter_map { |row| EnableBankingEntry::Processor.compute_external_id(row) }
        .to_set
    end

    def build
      return [] if account.blank?
      # An empty snapshot cannot distinguish an orphan from an account that has
      # simply never synced, so it yields nothing rather than everything.
      return [] if snapshot_external_ids.empty?

      entries = account.entries
        .where(source: "enable_banking", entryable_type: "Transaction", parent_entry_id: nil)
        .where.not(external_id: nil)
        .includes(entryable: [ :category, :taggings ])
        .to_a

      stored, orphaned = entries.partition { |entry| snapshot_external_ids.include?(entry.external_id) }
      survivors_by_key = stored.group_by { |entry| sibling_key(entry) }

      orphaned.filter_map do |entry|
        next if entry.transaction.pending?

        survivor = survivors_by_key[sibling_key(entry)]&.min_by { |candidate| [ candidate.created_at, candidate.id ] }
        next if survivor.nil?

        Candidate.new(entry: entry, survivor: survivor)
      end
    end

    # date, amount and currency derive only from fields both halves of a twin
    # report identically, so the surviving row is findable without re-parsing
    # the raw payload.
    def sibling_key(entry)
      [ entry.date, entry.amount, entry.currency ]
    end
end
