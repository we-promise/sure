class Entry < ApplicationRecord
  include Monetizable, Enrichable

  TRUTHY_VALUES = [ true, "true", "1", 1 ].freeze
  private_constant :TRUTHY_VALUES

  attr_accessor :unsplitting, :foreclosing

  monetize :amount

  belongs_to :account
  belongs_to :transfer, optional: true
  belongs_to :import, optional: true
  belongs_to :parent_entry, class_name: "Entry", optional: true
  belongs_to :emi_plan, optional: true
  belongs_to :reconciled_by_statement, class_name: "AccountStatement", optional: true

  # Mirrors chk_entries_reconciled_at_present_when_statement_set so a direct
  # assignment surfaces a validation error rather than a StatementInvalid.
  validates :reconciled_at, presence: true, if: -> { reconciled_by_statement_id.present? }

  has_many :child_entries, class_name: "Entry", foreign_key: :parent_entry_id, dependent: :destroy
  has_one :originated_emi_plan, class_name: "EmiPlan", foreign_key: :entry_id, dependent: :destroy

  delegated_type :entryable, types: Entryable::TYPES, dependent: :destroy
  accepts_nested_attributes_for :entryable

  validates :date, :name, :amount, :currency, presence: true
  validates :date, uniqueness: { scope: [ :account_id, :entryable_type ] }, if: -> { valuation? }
  validates :date, comparison: { greater_than: -> { min_supported_date } }
  validates :external_id, uniqueness: { scope: [ :account_id, :source ] }, if: -> { external_id.present? && source.present? }

  validate :cannot_unexclude_split_parent
  validate :split_child_date_matches_parent
  validate :cannot_edit_emi_purchase_amount_or_date
  validate :cannot_edit_emi_installment_amount_or_date

  before_destroy :prevent_individual_child_deletion, if: :split_child?
  before_destroy :prevent_emi_purchase_deletion, if: :emi_purchase?
  before_destroy :prevent_emi_installment_deletion, if: :emi_installment?

  scope :visible, -> {
    joins(:account).where(accounts: { status: [ "draft", "active" ] })
  }

  scope :chronological, -> {
    order(
      date: :asc,
      Arel.sql("CASE WHEN entries.entryable_type = 'Valuation' THEN 1 ELSE 0 END") => :asc,
      created_at: :asc,
      id: :asc
    )
  }

  scope :reverse_chronological, -> {
    order(
      date: :desc,
      Arel.sql("CASE WHEN entries.entryable_type = 'Valuation' THEN 1 ELSE 0 END") => :desc,
      created_at: :desc,
      id: :desc
    )
  }

  # Reconciliation scopes - see AddReconciliationToEntries
  scope :reconciled, -> { where.not(reconciled_at: nil) }
  scope :unreconciled, -> { where(reconciled_at: nil) }
  scope :reconciled_by, ->(statement) { where(reconciled_by_statement_id: statement) }

  # Pending transaction scopes - check Transaction.extra for provider pending flags
  # Works with any provider that stores pending status in extra["provider_name"]["pending"]
  scope :pending, -> {
    conditions = Transaction::PENDING_PROVIDERS.map { |p| "(transactions.extra -> '#{p}' ->> 'pending')::boolean = true" }
    joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(conditions.join(" OR "))
  }

  scope :excluding_pending, -> {
    # For non-Transaction entries (Trade, Valuation), always include
    # For Transaction entries, exclude if any provider marks it pending
    where(<<~SQL.squish)
      entries.entryable_type != 'Transaction'
      OR NOT EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.id = entries.entryable_id
        AND (#{Transaction::PENDING_CHECK_SQL})
      )
    SQL
  }

  scope :excluding_split_parents, -> {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM entries ce WHERE ce.parent_entry_id = entries.id
      )
    SQL
  }

  # Once a purchase is converted to an EMI plan, its generated installments
  # carry the real spend/balance impact — the original purchase entry itself
  # must not also count, or the balance double-counts (principal once via the
  # purchase, again via the installments summing back to it). This is
  # deliberately narrower than excluding_split_parents: unlike a split
  # parent, an emi_purchase entry stays visible/editable/searchable
  # everywhere else (categorization, search, rules, exports) — it's excluded
  # from balance reconstruction only.
  #
  # Only excludes entries backed by a plan that's still "live" for balance
  # purposes (active, or foreclosed after at least one installment posted).
  # A plan that was foreclosed before anything posted has its Transaction#kind
  # reverted to "standard" by EmiPlan#foreclose! — that purchase must count
  # again, so it's intentionally not excluded here.
  scope :excluding_emi_purchases, -> {
    where(<<~SQL.squish)
      NOT EXISTS (
        SELECT 1 FROM emi_plans ep
        WHERE ep.entry_id = entries.id
        AND (
          ep.status = 'active'
          OR EXISTS (
            SELECT 1 FROM entries installment
            WHERE installment.emi_plan_id = ep.id
            AND installment.date <= CURRENT_DATE
          )
        )
      )
    SQL
  }

  # Find stale pending transactions (pending for more than X days with no matching posted version)
  scope :stale_pending, ->(days: 8) {
    pending.where("entries.date < ?", days.days.ago.to_date)
  }

  # Family-scoped query for Enrichable#clear_ai_cache
  def self.family_scope(family)
    joins(:account).where(accounts: { family_id: family.id })
  end

  # Uncategorized, non-transfer transaction entries on draft or active accounts.
  # Caller is responsible for scoping to accessible entries before applying this scope.
  scope :uncategorized_transactions, -> {
    joins(:account)
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(accounts: { status: %w[draft active] })
      .where(transactions: { category_id: nil })
      .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
      .where(entries: { excluded: false })
  }

  # Returns uncategorized, non-transfer entries whose name matches the given filter string.
  # Used by the Quick Categorize Wizard to preview which transactions a rule would affect.
  # @param entries [ActiveRecord::Relation] pre-scoped entries (caller controls authorization)
  def self.uncategorized_matching(entries, filter, transaction_type = nil)
    sanitized = sanitize_sql_like(filter.gsub(/\s+/, " ").strip)
    scope = entries
              .uncategorized_transactions
              .where("BTRIM(REGEXP_REPLACE(entries.name, '[[:space:]]+', ' ', 'g')) ILIKE ?", "%#{sanitized}%")

    scope = case transaction_type
    when "income"  then scope.where("entries.amount < 0")
    when "expense" then scope.where("entries.amount >= 0")
    else scope
    end

    scope.includes(entryable: :merchant).order(entries: { date: :desc }).to_a
  end

  # Auto-exclude stale pending transactions for an account
  # Called during sync to clean up pending transactions that never posted
  # @param account [Account] The account to clean up
  # @param days [Integer] Number of days after which pending is considered stale (default: 8)
  # @return [Integer] Number of entries excluded
  def self.auto_exclude_stale_pending(account:, days: 8)
    stale_entries = account.entries.stale_pending(days: days).where(excluded: false)
    count = stale_entries.count

    if count > 0
      stale_entries.update_all(excluded: true, updated_at: Time.current)
      Rails.logger.info("Auto-excluded #{count} stale pending transaction(s) for account #{account.id} (#{account.name})")
    end

    count
  end

  # Retroactively reconcile pending transactions that have a matching posted version
  # This handles duplicates created before reconciliation code was deployed
  #
  # @param account [Account, nil] Specific account to clean up, or nil for all accounts
  # @param dry_run [Boolean] If true, only report what would be done without making changes
  # @param date_window [Integer] Days to search forward for posted matches (default: 8)
  # @param amount_tolerance [Float] Percentage difference allowed for fuzzy matching (default: 0.25)
  # @return [Hash] Stats about what was reconciled
  def self.reconcile_pending_duplicates(account: nil, dry_run: false, date_window: 8, amount_tolerance: 0.25)
    stats = { checked: 0, reconciled: 0, details: [] }

    not_pending_sql = Transaction::PENDING_PROVIDERS
      .map { |p| "(transactions.extra -> '#{p}' ->> 'pending')::boolean IS NOT TRUE" }
      .join(" AND ")

    # Get pending entries to check
    scope = Entry.pending.where(excluded: false)
    scope = scope.where(account: account) if account

    scope.includes(:account, :entryable).find_each do |pending_entry|
      stats[:checked] += 1
      acct = pending_entry.account

      # PRIORITY 1: Look for posted transaction with EXACT amount match
      # CRITICAL: Only search forward in time - posted date must be >= pending date
      exact_candidates = acct.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where.not(id: pending_entry.id)
        .where(currency: pending_entry.currency)
        .where(amount: pending_entry.amount)
        .where(date: pending_entry.date..(pending_entry.date + date_window.days)) # Posted must be ON or AFTER pending date
        .where(not_pending_sql)
        .limit(2) # Only need to know if 0, 1, or 2+ candidates
        .to_a # Load limited records to avoid COUNT(*) on .size

      # Handle exact match - auto-exclude only if exactly ONE candidate (high confidence)
      # Multiple candidates = ambiguous = skip to avoid excluding wrong entry
      if exact_candidates.size == 1
        posted_match = exact_candidates.first
        detail = {
          pending_id: pending_entry.id,
          pending_name: pending_entry.name,
          pending_amount: pending_entry.amount.to_f,
          pending_date: pending_entry.date,
          posted_id: posted_match.id,
          posted_name: posted_match.name,
          posted_amount: posted_match.amount.to_f,
          posted_date: posted_match.date,
          account: acct.name,
          match_type: "exact"
        }
        stats[:details] << detail
        stats[:reconciled] += 1

        unless dry_run
          pending_entry.update!(excluded: true)
          Rails.logger.info("Reconciled pending→posted duplicate: excluded entry #{pending_entry.id} (#{pending_entry.name}) matched to #{posted_match.id}")
        end
        next
      end

      # PRIORITY 2: If no exact match, try fuzzy amount match for tip adjustments
      # Store as SUGGESTION instead of auto-excluding (medium confidence)
      pending_amount = pending_entry.amount.abs
      min_amount = pending_amount
      max_amount = pending_amount * (1 + amount_tolerance)

      fuzzy_date_window = 3
      candidates = acct.entries
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where.not(id: pending_entry.id)
        .where(currency: pending_entry.currency)
        .where(date: pending_entry.date..(pending_entry.date + fuzzy_date_window.days)) # Posted ON or AFTER pending
        .where("ABS(entries.amount) BETWEEN ? AND ?", min_amount, max_amount)
        .where(not_pending_sql)

      # Match by name similarity (first 3 words)
      name_words = pending_entry.name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
      if name_words.present?
        matching_candidates = candidates.select do |c|
          c_words = c.name.downcase.gsub(/[^a-z0-9\s]/, "").split.first(3).join(" ")
          name_words == c_words
        end

        # Only suggest if there's exactly ONE matching candidate
        # Multiple matches = ambiguous (e.g., recurring gas station visits) = skip
        if matching_candidates.size == 1
          fuzzy_match = matching_candidates.first

          detail = {
            pending_id: pending_entry.id,
            pending_name: pending_entry.name,
            pending_amount: pending_entry.amount.to_f,
            pending_date: pending_entry.date,
            posted_id: fuzzy_match.id,
            posted_name: fuzzy_match.name,
            posted_amount: fuzzy_match.amount.to_f,
            posted_date: fuzzy_match.date,
            account: acct.name,
            match_type: "fuzzy_suggestion"
          }
          stats[:details] << detail

          unless dry_run
            # Store suggestion on the pending entry instead of auto-excluding
            pending_transaction = pending_entry.entryable
            if pending_transaction.is_a?(Transaction)
              existing_extra = pending_transaction.extra || {}
              unless existing_extra["potential_posted_match"].present?
                pending_transaction.update!(
                  extra: existing_extra.merge(
                    "potential_posted_match" => {
                      "entry_id"      => fuzzy_match.id,
                      "reason"        => "fuzzy_amount_match",
                      "posted_amount" => fuzzy_match.amount.to_s,
                      "confidence"    => "medium",
                      "dismissed"     => false,
                      "detected_at"   => Date.current.to_s
                    }
                  )
                )
                Rails.logger.info("Stored duplicate suggestion for entry #{pending_entry.id} (#{pending_entry.name}) → #{fuzzy_match.id}")
              end
            end
          end
        elsif matching_candidates.size > 1
          Rails.logger.info("Skipping fuzzy reconciliation for #{pending_entry.id} (#{pending_entry.name}): #{matching_candidates.size} ambiguous candidates")
        end
      end
    end

    stats
  end

  def classification
    amount.negative? ? "income" : "expense"
  end

  def lock_saved_attributes!
    super
    entryable.lock_saved_attributes!
  end

  def sync_account_later
    sync_start_date = [ date_previously_was, date ].compact.min unless destroyed?
    account.sync_later(window_start_date: sync_start_date)
  end

  def entryable_name_short
    entryable_type.demodulize.underscore
  end

  def balance_trend(entries, balances)
    Balance::TrendCalculator.new(self, entries, balances).trend
  end

  def linked?
    external_id.present?
  end

  # Reconciliation state, following the Quicken uncleared / cleared / reconciled
  # model. Only the last state is stored -- see AddReconciliationToEntries.
  #
  # @return [Symbol] :uncleared, :cleared or :reconciled
  def reconciliation_state
    return :reconciled if reconciled?
    return :cleared if cleared?

    :uncleared
  end

  # The institution has acknowledged this transaction: it either arrived from a
  # provider, or was entered by hand and later claimed by one (which stamps
  # external_id and source -- see Account::ProviderImportAdapter). Derived rather
  # than stored so it cannot drift, and deliberately not user-settable: this is a
  # fact about where the entry came from, not an opinion about it.
  def cleared?
    external_id.present? || source.present?
  end

  # A statement has been matched against this transaction. Unlike cleared?, this
  # is a judgement -- made by a statement import, or by the user directly -- so
  # it is stored and can be undone.
  def reconciled?
    reconciled_at.present?
  end

  # @param statement [AccountStatement, nil] the statement providing the evidence
  def mark_reconciled!(statement: nil, at: Time.current)
    update!(reconciled_at: at, reconciled_by_statement: statement)
  end

  def unmark_reconciled!
    update!(reconciled_at: nil, reconciled_by_statement: nil)
  end

  # Checks if entry should be protected from provider sync overwrites.
  # This does NOT prevent user from editing - only protects from automated sync.
  #
  # @return [Boolean] true if entry should be skipped during provider sync
  def protected_from_sync?
    excluded? || user_modified? || import_locked?
  end

  # Bulk-marks the entries of the given transactions as user-modified so a
  # later provider sync won't overwrite them (issue #1977). Used by merchant
  # merge/convert/unlink flows, which reassign merchant_id directly on
  # transactions and must protect that manual change from being reverted.
  #
  # Accepts a Transaction relation (preferred — the selection runs as a
  # subquery so large merges/unlinks don't materialize ids or hit SQL
  # parameter limits) or an explicit array of ids.
  #
  # @param transactions [ActiveRecord::Relation, Array<String>] Transactions or their ids
  # @return [void]
  def self.mark_user_modified_for_transactions!(transactions)
    entryable_ids =
      if transactions.is_a?(ActiveRecord::Relation)
        transactions.select(:id)
      else
        ids = Array(transactions).compact.uniq
        return if ids.empty?
        ids
      end

    where(entryable_type: "Transaction", entryable_id: entryable_ids).update_all(user_modified: true)
  end

  # Marks entry as user-modified after manual edit.
  # Called when user edits any field to prevent provider sync from overwriting.
  #
  # @return [Boolean] true if successfully marked
  def mark_user_modified!
    return true if user_modified?
    update!(user_modified: true)
  end

  # Returns the reason this entry is protected from sync, or nil if not protected.
  # Priority: excluded > user_modified > import_locked
  #
  # @return [Symbol, nil] :excluded, :user_modified, :import_locked, or nil
  def protection_reason
    return :excluded if excluded?
    return :user_modified if user_modified?
    return :import_locked if import_locked?
    nil
  end

  # Returns array of field names that are locked on entry and entryable.
  #
  # @return [Array<String>] locked field names
  def locked_field_names
    entry_keys = locked_attributes&.keys || []
    entryable_keys = entryable&.locked_attributes&.keys || []
    (entry_keys + entryable_keys).uniq
  end

  # Returns hash of locked field names to their lock timestamps.
  # Combines locked_attributes from both entry and entryable.
  # Parses ISO8601 timestamps stored in locked_attributes.
  #
  # @return [Hash{String => Time}] field name to lock timestamp
  def locked_fields_with_timestamps
    combined = (locked_attributes || {}).merge(entryable&.locked_attributes || {})
    combined.transform_values do |timestamp|
      Time.zone.parse(timestamp.to_s) rescue timestamp
    end
  end

  # Clears protection flags so provider sync can update this entry again.
  # Clears user_modified, import_locked flags, and all locked_attributes
  # on both the entry and its entryable.
  #
  # @return [void]
  def unlock_for_sync!
    self.class.transaction do
      update!(user_modified: false, import_locked: false, locked_attributes: {})
      entryable&.update!(locked_attributes: {})
    end
  end

  def split_parent?
    child_entries.exists?
  end

  def split_child?
    parent_entry_id.present?
  end

  # True for the original purchase entry once it's been converted into an EMI plan.
  def emi_purchase?
    originated_emi_plan.present?
  end

  # True for a generated installment entry (emi_plan_id present). The
  # one-time processing-fee entry is linked separately, through
  # EmiPlan#processing_fee_entry, and is NOT emi_plan_id-tagged — so this
  # returns false for it. See the note near cannot_edit_emi_installment_amount_or_date.
  def emi_installment?
    emi_plan_id.present?
  end

  # True for the one-time processing-fee entry generated alongside an EMI
  # plan (Transaction#kind == "emi_fee"). Unlike emi_purchase?/emi_installment?,
  # this entry isn't linked via emi_plan_id or originated_emi_plan — it's
  # only reachable through EmiPlan#processing_fee_entry — so kind is the only
  # way to identify it directly from the entry/transaction side.
  def emi_fee?
    transaction? && transaction.kind == "emi_fee"
  end

  # True for any entry that's part of an EMI plan in some form: the
  # original purchase, a generated installment, or the one-time processing
  # fee. Trade conversion (and similar "pick a fresh, unrelated transaction"
  # flows) needs to exclude all three, not just purchase/installment —
  # otherwise a fee entry could be converted into a Trade even though it
  # exists only because of, and is still tracked by, a live EmiPlan.
  def emi_linked?
    emi_purchase? || emi_installment? || emi_fee?
  end

  # True while this entry's amount/date must stay locked because of an EMI
  # plan. Same bar as the model validations
  # (cannot_edit_emi_purchase_amount_or_date / ..._installment_...) and
  # Transaction#cannot_change_kind_of_active_emi_entry.
  #
  # - Purchase entry: locked while the plan is active, or once foreclosed
  #   if any installment ever posted (that history needs to stay
  #   reconciled with the purchase). A plan foreclosed before anything
  #   posted has nothing left to desync, so it unlocks.
  # - Installment entry: locked while its plan is still active (matches
  #   the schedule it was generated from), OR if it's already posted
  #   (date <= today) — posted installments represent money that already
  #   moved and stay locked even after the plan is foreclosed, same as
  #   prevent_emi_installment_deletion protects them from deletion. A
  #   never-posted installment on a foreclosed plan wouldn't normally
  #   exist (foreclose! deletes remaining future installments), but the
  #   date check covers it defensively either way.
  def emi_date_locked?
    if emi_purchase?
      plan = originated_emi_plan
      plan.active? || plan.posted_installments.exists?
    elsif emi_installment?
      (emi_plan.present? && emi_plan.active?) || date <= Date.current
    else
      false
    end
  end

  # Splits this entry into child entries. Marks parent as excluded.
  #
  # @param splits [Array<Hash>] array of { name:, amount:, category_id:, excluded: } hashes
  # @return [Array<Entry>] the created child entries
  def split!(splits)
    total = splits.sum { |s| s[:amount].to_d }
    unless total == amount
      raise ActiveRecord::RecordInvalid.new(self), "Split amounts must sum to parent amount (expected #{amount}, got #{total})"
    end

    self.class.transaction do
      children = splits.map do |split_attrs|
        child_transaction = Transaction.new(
          category_id: split_attrs[:category_id],
          merchant_id: entryable.try(:merchant_id),
          kind: entryable.try(:kind)
        )

        child_entries.create!(
          account: account,
          date: date,
          name: split_attrs[:name],
          amount: split_attrs[:amount],
          currency: currency,
          excluded: TRUTHY_VALUES.include?(split_attrs[:excluded]),
          entryable: child_transaction
        )
      end

      update!(excluded: true)
      mark_user_modified!

      children
    end
  end

  # Removes split children and restores parent entry.
  def unsplit!
    self.class.transaction do
      child_entries.each do |child|
        child.unsplitting = true
        child.destroy!
      end
      update!(excluded: false)
    end
  end

  class << self
    def search(params)
      EntrySearch.new(params).build_query(all)
    end

    # arbitrary cutoff date to avoid expensive sync operations
    def min_supported_date
      30.years.ago.to_date
    end

    # Bulk update entries with the given parameters.
    #
    # Tags are handled separately from other entryable attributes because they use
    # a join table (taggings) rather than a direct column. This means:
    # - category_id: nil means "no category" (column value)
    # - tag_ids: [] means "delete all taggings" (join table operation)
    #
    # To avoid accidentally clearing tags when only updating other fields,
    # tags are only modified when explicitly requested via update_tags: true.
    #
    # @param bulk_update_params [Hash] The parameters to update
    # @param update_tags [Boolean] Whether to update tags (default: false)
    def bulk_update!(bulk_update_params, update_tags: false)
      bulk_attributes = {
        date: bulk_update_params[:date],
        notes: bulk_update_params[:notes],
        name: bulk_update_params[:name],
        entryable_attributes: {
          category_id: bulk_update_params[:category_id],
          merchant_id: bulk_update_params[:merchant_id]
        }.compact_blank
      }.compact_blank

      tag_ids = Array.wrap(bulk_update_params[:tag_ids]).reject(&:blank?)
      has_updates = bulk_attributes.present? || update_tags

      return 0 unless has_updates

      entries = all.includes(:originated_emi_plan, :emi_plan).to_a

      # emi_date_locked? calls EmiPlan#posted_installments.exists? for every
      # emi_purchase entry, which is one query per foreclosed plan when run
      # inside the loop below. Batch that lookup into a single query up
      # front instead, and pass the result in so the per-entry check stays
      # in-memory.
      originated_plan_ids = entries.filter_map { |entry| entry.originated_emi_plan&.id }
      plan_ids_with_posted_installments = Entry
        .where(emi_plan_id: originated_plan_ids)
        .where("entries.date <= ?", Date.current)
        .distinct
        .pluck(:emi_plan_id)
        .to_set

      transaction do
        entries.each do |entry|
          changed = false

          # Update standard attributes
          if bulk_attributes.present?
            attrs = bulk_attributes.dup
            attrs.delete(:date) if entry.split_child? || emi_date_locked_for_bulk_update?(entry, plan_ids_with_posted_installments)
            attrs.delete(:entryable_attributes) unless entry.transaction?

            if attrs.present?
              attrs[:entryable_attributes] = attrs[:entryable_attributes].dup if attrs[:entryable_attributes].present?
              attrs[:entryable_attributes][:id] = entry.entryable_id if attrs[:entryable_attributes].present?
              entry.update! attrs
              entry.transaction.record_category_usage! if entry.transaction?
              changed = true
            end
          end

          # Handle tags separately - only when explicitly requested
          if update_tags && entry.transaction?
            entry.transaction.tag_ids = tag_ids
            entry.transaction.save!
            entry.entryable.lock_attr!(:tag_ids) if entry.transaction.tags.any?
            changed = true
          end

          if changed
            entry.lock_saved_attributes!
            entry.mark_user_modified!
          end
        end
      end

      all.size
    end

    private

      # Mirrors Entry#emi_date_locked?, but takes a precomputed set of
      # originated-plan ids that have at least one posted installment
      # instead of calling EmiPlan#posted_installments.exists? per entry.
      # Used by bulk_update! to avoid an N+1 query across foreclosed plans.
      def emi_date_locked_for_bulk_update?(entry, plan_ids_with_posted_installments)
        if entry.emi_purchase?
          plan = entry.originated_emi_plan
          plan.active? || plan_ids_with_posted_installments.include?(plan.id)
        elsif entry.emi_installment?
          (entry.emi_plan.present? && entry.emi_plan.active?) || entry.date <= Date.current
        else
          false
        end
      end
  end

  private

    def cannot_unexclude_split_parent
      return unless excluded_changed?(from: true, to: false) && split_parent?

      errors.add(:excluded, "cannot be toggled off for a split transaction")
    end

    def split_child_date_matches_parent
      return unless split_child? && date_changed?
      return unless parent_entry.present?
      return if date == parent_entry.date

      errors.add(:date, "must match the parent transaction date for split children")
    end

    # The parent purchase's amount is what the whole installment schedule was
    # computed from. Letting it change while the plan is still live would
    # silently desync the entry from its EmiPlan (the schedule wouldn't
    # reflect the new amount, and totals would no longer reconcile).
    # Foreclose the plan first if the purchase needs correcting.
    #
    # Scoped to a "live" plan — active, or foreclosed but with posted
    # installment history — same bar used by Transaction's kind guard and
    # by #prevent_emi_purchase_deletion. A plan foreclosed before anything
    # ever posted has nothing left to desync, so editing is allowed again.
    def cannot_edit_emi_purchase_amount_or_date
      return unless emi_purchase? && persisted? && (amount_changed? || date_changed?)
      return unless emi_date_locked?

      errors.add(:base, "Amount and date can't be changed on a purchase that's been converted to an EMI plan. Foreclose the plan first.")
    end

    # Installment entries are generated from the amortization schedule and
    # dated by EmiPlan#build!. Editing one directly (manually or via a
    # provider sync overwrite) would break the "schedule sums to principal"
    # guarantee and desync it from its siblings while the plan is still
    # live. Foreclose + re-create instead.
    #
    # Once foreclosed, remaining future installments have already been
    # deleted by EmiPlan#foreclose! — so any installment entry that's still
    # around at that point is a posted one, kept intentionally as real spend
    # history, and edits to it behave like an ordinary transaction.
    def cannot_edit_emi_installment_amount_or_date
      return unless emi_installment? && persisted? && (amount_changed? || date_changed?)
      return unless emi_date_locked?

      errors.add(:base, "Amount and date can't be changed on an individual EMI installment. Foreclose the plan to cancel remaining installments.")
    end

    # Note: the one-time processing-fee entry (Transaction#kind == "emi_fee")
    # is intentionally NOT guarded here. It doesn't feed the amortization
    # schedule or any reconciliation total — it's a plain one-time expense
    # that happens to have been created alongside a plan — so editing its
    # amount or date is safe and behaves like any other transaction.

    def prevent_individual_child_deletion
      return if destroyed_by_association || unsplitting

      throw :abort
    end

    # Deleting the parent purchase directly would cascade-destroy its
    # EmiPlan (has_one dependent: :destroy) while the installment entries
    # only get nullified (dependent: :nullify, deliberately, so posted
    # history survives — see EmiPlan#foreclose!). That combination orphans
    # every installment: still real budget-counted transactions, but with no
    # plan link, so they can no longer be viewed as a schedule or
    # foreclosed. Foreclose the plan first — that safely tears down future
    # installments and keeps posted ones intact — then the entry can be
    # deleted normally.
    #
    # Only blocks while the plan still has installments tied to it (active,
    # or foreclosed with posted history). A plan foreclosed before anything
    # ever posted has nothing left to orphan — Transaction#kind has already
    # reverted to "standard" in that case — so deletion is allowed.
    def prevent_emi_purchase_deletion
      return if destroyed_by_association

      plan = originated_emi_plan
      return unless plan.active? || plan.posted_installments.exists?

      errors.add(:base, "Can't delete a purchase that's been converted to an EMI plan. Foreclose the plan first.")
      throw :abort
    end

    # Individual installments must never be deleted one at a time — that
    # would silently break the amortization schedule and the plan's totals.
    # The only supported way to remove installments is EmiPlan#foreclose!,
    # which removes future ones as a deliberate, atomic operation and keeps
    # posted ones untouched.
    def prevent_emi_installment_deletion
      return if destroyed_by_association || foreclosing

      errors.add(:base, "Can't delete an individual EMI installment directly. Foreclose the plan to cancel remaining installments.")
      throw :abort
    end
end
