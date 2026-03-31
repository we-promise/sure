class Entry < ApplicationRecord
  include Monetizable, Enrichable

  attr_accessor :unsplitting

  monetize :amount

  belongs_to :account
  belongs_to :transfer, optional: true
  belongs_to :import, optional: true
  belongs_to :parent_entry, class_name: "Entry", optional: true

  has_many :child_entries, class_name: "Entry", foreign_key: :parent_entry_id, dependent: :destroy
  has_one :bond_lot, dependent: :destroy

  delegated_type :entryable, types: Entryable::TYPES, dependent: :destroy
  accepts_nested_attributes_for :entryable

  validates :date, :name, :amount, :currency, presence: true
  validates :date, uniqueness: { scope: [ :account_id, :entryable_type ] }, if: -> { valuation? }
  validates :date, comparison: { greater_than: -> { min_supported_date } }
  validates :external_id, uniqueness: { scope: [ :account_id, :source ] }, if: -> { external_id.present? && source.present? }

  validate :cannot_unexclude_split_parent
  validate :split_child_date_matches_parent

  before_destroy :prevent_individual_child_deletion, if: :split_child?

  scope :visible, -> {
    joins(:account).where(accounts: { status: [ "draft", "active" ] })
  }

  scope :chronological, -> {
    order(
      date: :asc,
      Arel.sql("CASE WHEN entries.entryable_type = 'Valuation' THEN 1 ELSE 0 END") => :asc,
      created_at: :asc
    )
  }

  scope :reverse_chronological, -> {
    order(
      date: :desc,
      Arel.sql("CASE WHEN entries.entryable_type = 'Valuation' THEN 1 ELSE 0 END") => :desc,
      created_at: :desc
    )
  }

  # Pending transaction scopes - check Transaction.extra for provider pending flags
  # Works with any provider that stores pending status in extra["provider_name"]["pending"]
  scope :pending, -> {
    joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(<<~SQL.squish)
        (transactions.extra -> 'simplefin' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'plaid' ->> 'pending')::boolean = true
        OR (transactions.extra -> 'lunchflow' ->> 'pending')::boolean = true
      SQL
  }

  scope :excluding_pending, -> {
    # For non-Transaction entries (Trade, Valuation), always include
    # For Transaction entries, exclude if pending flag is true
    where(<<~SQL.squish)
      entries.entryable_type != 'Transaction'
      OR NOT EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.id = entries.entryable_id
        AND (
          (t.extra -> 'simplefin' ->> 'pending')::boolean = true
          OR (t.extra -> 'plaid' ->> 'pending')::boolean = true
          OR (t.extra -> 'lunchflow' ->> 'pending')::boolean = true
        )
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

  # Find stale pending transactions (pending for more than X days with no matching posted version)
  scope :stale_pending, ->(days: 8) {
    pending.where("entries.date < ?", days.days.ago.to_date)
  }

  # Family-scoped query for Enrichable#clear_ai_cache
  def self.family_scope(family)
    joins(:account).where(accounts: { family_id: family.id })
  end

  # Counts uncategorized, non-transfer entries in the given scope.
  # Used by the Quick Categorize Wizard to show the remaining count.
  # @param entries [ActiveRecord::Relation] pre-scoped entries (caller controls authorization)
  def self.uncategorized_count(entries)
    entries
      .joins(:account)
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(accounts: { status: %w[draft active] })
      .where(transactions: { category_id: nil })
      .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
      .where(entries: { excluded: false })
      .count
  end

  # Returns uncategorized, non-transfer entries whose name matches the given filter string.
  # Used by the Quick Categorize Wizard to preview which transactions a rule would affect.
  # @param entries [ActiveRecord::Relation] pre-scoped entries (caller controls authorization)
  def self.uncategorized_matching(entries, filter, transaction_type = nil)
    sanitized = sanitize_sql_like(filter.gsub(/\s+/, " ").strip)
    scope = entries
              .joins(:account)
                  .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
                  .where(accounts: { status: %w[draft active] })
                  .where(transactions: { category_id: nil })
                  .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
                  .where(entries: { excluded: false })
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
        .where(<<~SQL.squish)
          (transactions.extra -> 'simplefin' ->> 'pending')::boolean IS NOT TRUE
          AND (transactions.extra -> 'plaid' ->> 'pending')::boolean IS NOT TRUE
          AND (transactions.extra -> 'lunchflow' ->> 'pending')::boolean IS NOT TRUE
        SQL
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
        .where(<<~SQL.squish)
          (transactions.extra -> 'simplefin' ->> 'pending')::boolean IS NOT TRUE
          AND (transactions.extra -> 'plaid' ->> 'pending')::boolean IS NOT TRUE
          AND (transactions.extra -> 'lunchflow' ->> 'pending')::boolean IS NOT TRUE
        SQL

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
                      "entry_id" => fuzzy_match.id,
                      "reason" => "fuzzy_amount_match",
                      "posted_amount" => fuzzy_match.amount.to_s,
                      "detected_at" => Date.current.to_s
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

  # Checks if entry should be protected from provider sync overwrites.
  # This does NOT prevent user from editing - only protects from automated sync.
  #
  # @return [Boolean] true if entry should be skipped during provider sync
  def protected_from_sync?
    excluded? || user_modified? || import_locked?
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

  # Splits this entry into child entries. Marks parent as excluded.
  #
  # @param splits [Array<Hash>] array of { name:, amount:, category_id: } hashes
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
        entryable_attributes: {
          category_id: bulk_update_params[:category_id],
          merchant_id: bulk_update_params[:merchant_id]
        }.compact_blank
      }.compact_blank

      tag_ids = Array.wrap(bulk_update_params[:tag_ids]).reject(&:blank?)
      has_updates = bulk_attributes.present? || update_tags

      return 0 unless has_updates

      transaction do
        all.each do |entry|
          changed = false

          # Update standard attributes
          if bulk_attributes.present?
            attrs = bulk_attributes.dup
            attrs.delete(:date) if entry.split_child?

            if attrs.present?
              attrs[:entryable_attributes] = attrs[:entryable_attributes].dup if attrs[:entryable_attributes].present?
              attrs[:entryable_attributes][:id] = entry.entryable_id if attrs[:entryable_attributes].present?
              entry.update! attrs
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

    def prevent_individual_child_deletion
      return if destroyed_by_association || unsplitting

      throw :abort
    end
end
