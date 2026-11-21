# Folds one security row into another that stands for the same instrument and
# deletes it, moving everything that references it: holdings, trades, lots,
# prices, splits and tags. Rows the target already has for the same key win,
# except holdings, where the most recently written row for an
# (account, date, currency) is kept. Accounts that referenced the merged row
# are synced afterwards so their holdings and balances are rebuilt on one row.
class Security::Merger
  def initialize(from:, into:)
    @from = from
    @into = into
  end

  # `condition` is checked against the locked source row, for callers whose
  # reason to merge could have changed since they last read it.
  def merge!(condition: nil)
    return into if from.id == into.id

    account_ids = Security.transaction do
      locked = Security.where(id: [ from.id, into.id ]).order(:id).lock.to_a
      source = locked.find { |security| security.id == from.id }
      # A concurrent merge already removed the row.
      next [] unless locked.size == 2
      next [] if condition && !condition.call(source)

      referencing_account_ids.tap do
        now = Time.current
        move_holdings!(now)
        Trade.where(security_id: from.id).update_all(security_id: into.id, updated_at: now)
        move_lots!(now)
        move_unless_target_has(Security::Price, :date, :currency)
        move_unless_target_has(Security::Split, :ex_date)
        move_taggings!
        into.update!(name: from.name) if into.name.blank? && from.name.present?
        source.reload.destroy!
      end
    end

    Account.where(id: account_ids).find_each(&:sync_later)
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

    def move_holdings!(now)
      collisions = Holding.where(security_id: from.id)
        .joins(Holding.sanitize_sql_array([ <<~SQL, into.id ]))
          INNER JOIN holdings kept ON kept.security_id = ?
            AND kept.account_id = holdings.account_id
            AND kept.date = holdings.date
            AND kept.currency = holdings.currency
        SQL
        .pluck("holdings.id", "holdings.updated_at", "kept.id", "kept.updated_at")

      stale_ids = collisions.map { |id, updated_at, kept_id, kept_updated_at| updated_at > kept_updated_at ? kept_id : id }
      Holding.where(id: stale_ids).delete_all

      Holding.where(security_id: from.id).update_all(security_id: into.id, updated_at: now)
      Holding.where(provider_security_id: from.id).update_all(provider_security_id: into.id, updated_at: now)
      # A holding remapped away from a provider security that is now the
      # security it points to is no longer remapped.
      Holding.where(security_id: into.id, provider_security_id: into.id)
        .update_all(provider_security_id: nil, security_locked: false, updated_at: now)
    end

    def move_lots!(now)
      lots = HoldingLot.where(security_id: from.id)
      HoldingLot.move!(derived: lots.derived, opening: lots.opening, to: into)
      HoldingLot.where(origin_security_id: from.id).update_all(origin_security_id: into.id, updated_at: now)
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
