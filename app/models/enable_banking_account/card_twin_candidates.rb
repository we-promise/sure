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

  # category, tag_ids and notes are what would move to the surviving row rather
  # than what the duplicate holds: they are already narrowed to fields the
  # survivor lacks and is willing to accept.
  #
  # blockers are the things that cannot be carried across at all, so the UI
  # unticks them. A transfer-linked transaction cascades
  # (add_foreign_key "transfers", "transactions", on_delete: :cascade), which
  # destroys the transfer and strips the link from the counterpart transaction on
  # the other account.
  Candidate = Struct.new(:entry, :survivor, :category, :tag_ids, :notes, :blockers, keyword_init: true) do
    def blocked? = blockers.any?

    def transfers_anything? = category.present? || tag_ids.any? || notes.present?

    # Carries whatever the survivor can accept across, then destroys the
    # duplicate. Marking the survivor user_modified mirrors
    # Transaction#merge_with_duplicate!, so a later sync does not revert what was
    # just moved onto it.
    def remove!
      ApplicationRecord.transaction do
        survivor_transaction = survivor.transaction

        survivor_transaction.update!(category: category) if category.present?
        survivor_transaction.update!(tag_ids: tag_ids) if tag_ids.any?
        survivor.update!(notes: notes) if notes.present?
        survivor.mark_user_modified! if transfers_anything?

        entry.destroy!
      end
    end
  end

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
        .includes(entryable: [ :category, :taggings, :transfer_as_inflow, :transfer_as_outflow,
                              { attachments_attachments: :blob } ])
        .to_a

      stored, orphaned = entries.partition { |entry| snapshot_external_ids.include?(entry.external_id) }
      survivors_by_key = stored.group_by { |entry| sibling_key(entry) }

      orphaned.filter_map do |entry|
        next if entry.transaction.pending?

        survivor = survivors_by_key[sibling_key(entry)]&.min_by { |candidate| [ candidate.created_at, candidate.id ] }
        next if survivor.nil?

        build_candidate(entry, survivor)
      end
    end

    def build_candidate(entry, survivor)
      transaction = entry.transaction
      blockers = []
      # Transaction::Transferable#transfer, not the transfer_id column: the link
      # lives on transfers.inflow_transaction_id / outflow_transaction_id, which
      # is also what the cascading foreign key is declared on.
      blockers << :transfer if transaction.transfer.present?
      blockers << :attachment if transaction.attachments.attached?

      # Mirrors Transaction#merge_with_duplicate! (transaction.rb:304): a
      # survivor the user has already protected is never written to.
      inheritable = !survivor.protected_from_sync?
      survivor_transaction = survivor.transaction

      Candidate.new(
        entry: entry,
        survivor: survivor,
        category: (transaction.category if inheritable && survivor_transaction.category_id.blank?),
        tag_ids: (inheritable && survivor_transaction.tag_ids.empty? ? transaction.tag_ids : []),
        notes: (entry.notes.presence if inheritable && survivor.notes.blank?),
        blockers: blockers
      )
    end

    # date, amount and currency derive only from fields both halves of a twin
    # report identically, so the surviving row is findable without re-parsing
    # the raw payload.
    def sibling_key(entry)
      [ entry.date, entry.amount, entry.currency ]
    end
end
