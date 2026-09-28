class AddOpenObservationConflictIndexToFinancekitConflicts < ActiveRecord::Migration[8.1]
  INDEX_NAME = "financekit_conflicts_open_observation".freeze

  def up
    # Two publishers can share one account lineage — a replacement device keeps
    # the lineage of the device it replaces — so both could raise the same
    # balance disagreement before either saw the other's row. Keep the first
    # question and drop its copies before the index makes them impossible.
    execute <<~SQL
      DELETE FROM financekit_conflicts AS victim
      USING financekit_conflicts AS keeper
      WHERE victim.status = 'open'
        AND keeper.status = 'open'
        AND victim.kind = 'balance_observation_conflict'
        AND keeper.kind = 'balance_observation_conflict'
        AND victim.financekit_account_lineage_id = keeper.financekit_account_lineage_id
        AND victim.details = keeper.details
        AND (keeper.created_at, keeper.id) < (victim.created_at, victim.id)
    SQL

    # details carries the observation the conflict is about — source id, kind and
    # the canonical observed_at — and jsonb equality normalizes key order, so one
    # open question per lineage and observation.
    add_index :financekit_conflicts, [ :financekit_account_lineage_id, :details ],
      unique: true, name: INDEX_NAME,
      where: "status = 'open' AND kind = 'balance_observation_conflict'"
  end

  def down
    remove_index :financekit_conflicts, name: INDEX_NAME
  end
end
