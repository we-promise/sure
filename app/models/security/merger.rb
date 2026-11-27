# Folds one security row into another that stands for the same instrument and
# deletes it, moving everything that references it: holdings, trades, lots,
# prices, splits and tags. Rows the target already has for the same key win,
# except holdings, where the most recently written row for an
# (account, date, currency) is kept. Accounts that referenced the merged row
# are synced afterwards so their holdings and balances are rebuilt on one row.
class Security::Merger
  COUNTS = %i[holdings_moved holdings_removed trades lots references].freeze

  # What the last merge! moved, and the accounts it touched.
  attr_reader :counts, :account_ids

  # Merges each of `sources` into `into` in one transaction, so a group
  # merges whole or not at all, and adds the accounts it touched to
  # `account_ids` once it commits. Returns the summed counts. A task merging
  # several groups calls sync_accounts after its last merge: a sync queued
  # between merges can be absorbed by one already running.
  def self.merge_group!(sources, into:, account_ids:)
    counts = COUNTS.index_with(0)
    touched = Set.new

    Security.transaction do
      sources.each do |source|
        merger = new(from: source, into: into)
        merger.merge!(sync: false)
        merger.counts.each { |key, value| counts[key] += value }
        touched.merge(merger.account_ids)
      end
    end

    account_ids.merge(touched)
    counts
  end

  # Queues one sync per account. A failed dispatch is logged and the rest
  # still go out: the merges are committed, so a rerun cannot repeat them.
  def self.sync_accounts(account_ids)
    Account.where(id: account_ids.to_a).find_each do |account|
      account.sync_later
    rescue StandardError => e
      Rails.logger.error("Security merge: sync dispatch failed for account #{account.id}: #{e.message}")
    end
  end

  def initialize(from:, into:)
    @from = from
    @into = into
    @counts = COUNTS.index_with(0)
    @account_ids = []
  end

  # `condition` is checked against the locked source row, for callers whose
  # reason to merge could have changed since they last read it. `sync: false`
  # leaves syncing the affected accounts (account_ids) to the caller.
  def merge!(condition: nil, sync: true)
    return into if from.id == into.id

    @account_ids = Security.transaction do
      locked = Security.where(id: [ from.id, into.id ]).order(:id).lock.to_a
      source = locked.find { |security| security.id == from.id }
      # A concurrent merge already removed the row.
      next [] unless locked.size == 2
      next [] if condition && !condition.call(source)

      referencing_account_ids.tap do
        now = Time.current
        move_holdings!
        @counts[:trades] = Trade.where(security_id: from.id).update_all(security_id: into.id, updated_at: now)
        move_lots!(now)
        move_unless_target_has(Security::Price, :date, :currency)
        move_unless_target_has(Security::Split, :ex_date)
        move_taggings!
        source.reload.destroy!
        # After the source is gone, and without validating: another row of
        # the same ticker can still exist while a group is merged.
        into.update_attribute(:name, from.name) if into.name.blank? && from.name.present?
      end
    end

    Account.where(id: @account_ids).find_each(&:sync_later) if sync
    into
  end

  private
    attr_reader :from, :into

    def referencing_account_ids
      trade_entries = Entry.where(entryable_type: "Trade", entryable_id: Trade.where(security_id: from.id).select(:id))
      lots = HoldingLot.where(security_id: from.id).or(HoldingLot.where(origin_security_id: from.id))
      holdings = Holding.where(security_id: from.id).or(Holding.where(provider_security_id: from.id))

      [ holdings, trade_entries, lots ].flat_map { |scope| scope.distinct.pluck(:account_id) }.uniq
    end

    # Holdings keep the time they were written: it decides which row wins a
    # collision with a later source in the group, and the current provider
    # holdings are read by their latest write date.
    def move_holdings!
      collisions = Holding.where(security_id: from.id)
        .joins(Holding.sanitize_sql_array([ <<~SQL, into.id ]))
          INNER JOIN holdings kept ON kept.security_id = ?
            AND kept.account_id = holdings.account_id
            AND kept.date = holdings.date
            AND kept.currency = holdings.currency
        SQL
        .pluck("holdings.id", "holdings.updated_at", "kept.id", "kept.updated_at")

      stale_ids = collisions.map { |id, updated_at, kept_id, kept_updated_at| updated_at > kept_updated_at ? kept_id : id }
      @counts[:holdings_removed] = Holding.where(id: stale_ids).delete_all

      @counts[:holdings_moved] = Holding.where(security_id: from.id).update_all(security_id: into.id)
      @counts[:references] += Holding.where(provider_security_id: from.id).update_all(provider_security_id: into.id)
      # A holding remapped away from a provider security that is now the
      # security it points to is no longer remapped.
      Holding.where(security_id: into.id, provider_security_id: into.id)
        .update_all(provider_security_id: nil, security_locked: false)
    end

    def move_lots!(now)
      lots = HoldingLot.where(security_id: from.id)
      @counts[:lots] = lots.count
      HoldingLot.move!(derived: lots.derived, opening: lots.opening, to: into)
      @counts[:references] += HoldingLot.where(origin_security_id: from.id).update_all(origin_security_id: into.id, updated_at: now)
    end

    def move_unless_target_has(model, *key_columns)
      table = model.arel_table
      kept = table.alias("kept")
      same_key = key_columns.map { |column| kept[column].eq(table[column]) }.reduce(:and)
      kept_row = Arel::SelectManager.new.from(kept).project(Arel.sql("1")).where(kept[:security_id].eq(into.id).and(same_key))

      rows = model.where(security_id: from.id)
      rows.where(kept_row.exists).delete_all
      rows.update_all(security_id: into.id, updated_at: Time.current)
    end

    def move_taggings!
      taggings = Tagging.where(taggable_type: "Security", taggable_id: from.id)
      taggings.where(tag_id: Tagging.where(taggable_type: "Security", taggable_id: into.id).select(:tag_id)).delete_all
      taggings.update_all(taggable_id: into.id, updated_at: Time.current)
    end
end
