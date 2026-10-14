class AddUniqueTransactionIndexesToTransfers < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Transaction::TRANSFER_KINDS at the time of writing.
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment investment_contribution].freeze

  # A transaction may belong to at most one transfer, on either side. Until now
  # only the (inflow, outflow) pair was unique in the database; per-column
  # uniqueness was a check-then-insert validation, so concurrent syncs running
  # Family#auto_match_transfers! could put one transaction into two transfers.
  #
  # Existing duplicates are resolved first, or the unique indexes cannot be
  # built. Per conflicting group the kept transfer is chosen deterministically:
  # confirmed before pending, then one with fee transactions, then the oldest
  # (created_at, then id). Every other transfer that shares a transaction with
  # an already kept one is deleted. For each deleted transfer, as
  # Transfer#destroy! would do:
  #   - its fee transactions (normally none on auto-matched transfers) are kept
  #     as standalone transactions: transactions.transfer_id is set to NULL;
  #   - each of its inflow/outflow transactions that is no longer part of any
  #     remaining transfer (on either side) gets its entry's idempotency_key
  #     cleared and, if the deleted transfer was confirmed, a transfer kind
  #     reset to "standard" (a pending transfer never set the kind);
  #   - if it was confirmed and shares a transaction with a kept confirmed
  #     transfer, the kept transfer's legs get the kinds confirm! gives them,
  #     since the deleted transfer's confirm! may have overwritten them.
  # Entries of all affected transactions are touched so cached reports refresh.
  # Deleted pairs are not recorded as rejected, so the next sync may match a
  # freed transaction again, now protected by these indexes.
  def up
    replace_index :inflow_transaction_id, unique: true
    replace_index :outflow_transaction_id, unique: true
  end

  # The indexes are restored as non-unique; deleted duplicate transfers are not.
  def down
    replace_index :inflow_transaction_id, unique: false
    replace_index :outflow_transaction_id, unique: false
  end

  private
    # Builds the replacement index under a temporary name before touching the
    # existing one, so the column is never left without a valid index: if a
    # concurrent sync inserts a duplicate and the unique build fails, only the
    # temporary index is INVALID and the old index keeps serving queries. A re-run
    # drops that leftover and tries again. Duplicates are resolved immediately
    # before each unique build to keep that window as small as possible.
    #
    # If a previous run stopped after dropping the old index but before the
    # rename, the replacement is already built and valid. The swap is finished
    # instead of dropping it, which would leave the column without any index
    # (and without uniqueness) while it is rebuilt.
    def replace_index(column, unique:)
      name = "index_transfers_on_#{column}"
      temp_name = "#{name}_new"

      if !index_name_exists?(:transfers, name) && valid_index?(temp_name, unique: unique)
        rename_index :transfers, temp_name, name
        return
      end

      resolve_duplicate_transfers if unique

      remove_index :transfers, name: temp_name, if_exists: true, algorithm: :concurrently
      add_index :transfers, column, name: temp_name, unique: unique, algorithm: :concurrently
      remove_index :transfers, name: name, if_exists: true, algorithm: :concurrently
      rename_index :transfers, temp_name, name
    end

    def resolve_duplicate_transfers
      rows = select_rows(<<~SQL.squish)
        SELECT t.id, t.inflow_transaction_id, t.outflow_transaction_id, t.status
        FROM transfers t
        WHERE t.inflow_transaction_id IN (
            SELECT inflow_transaction_id FROM transfers GROUP BY inflow_transaction_id HAVING COUNT(*) > 1
          )
          OR t.outflow_transaction_id IN (
            SELECT outflow_transaction_id FROM transfers GROUP BY outflow_transaction_id HAVING COUNT(*) > 1
          )
        ORDER BY
          (t.status = 'confirmed') DESC,
          EXISTS (SELECT 1 FROM transactions f WHERE f.transfer_id = t.id) DESC,
          t.created_at ASC,
          t.id ASC
      SQL
      return if rows.empty?

      kept_by_transaction = {}
      losers = []
      rows.each do |id, inflow_id, outflow_id, status|
        if kept_by_transaction.key?(inflow_id) || kept_by_transaction.key?(outflow_id)
          losers << { id: id, transaction_ids: [ inflow_id, outflow_id ], confirmed: status == "confirmed" }
        else
          kept = { id: id, confirmed: status == "confirmed" }
          kept_by_transaction[inflow_id] = kept
          kept_by_transaction[outflow_id] = kept
        end
      end

      loser_ids = losers.map { |loser| loser[:id] }
      touched_ids = losers.flat_map { |loser| loser[:transaction_ids] }.uniq
      freed_ids = touched_ids.reject { |id| kept_by_transaction.key?(id) }
      # Only a confirmed transfer set transfer kinds (Transfer#confirm!); a
      # pending one left them as they were, so they predate the match and stay.
      kind_reset_ids = losers.select { |loser| loser[:confirmed] }.flat_map { |loser| loser[:transaction_ids] }.uniq & freed_ids
      # A confirmed loser's confirm! may have run after the kept transfer's and
      # rewritten the shared transaction's kind for its own destination.
      rederive_ids = losers.select { |loser| loser[:confirmed] }.flat_map do |loser|
        loser[:transaction_ids].filter_map { |id| kept_by_transaction[id] }.select { |kept| kept[:confirmed] }.map { |kept| kept[:id] }
      end.uniq

      say "Removing #{loser_ids.size} duplicate transfer(s); unlinking #{freed_ids.size} transaction(s)"

      # A freed id can still be the other-side endpoint of a surviving transfer
      # outside the conflicting groups (inflow here, outflow there); only reset
      # transactions no remaining transfer references.
      unreferenced = <<~SQL.squish
        NOT EXISTS (
          SELECT 1 FROM transfers r
          WHERE r.inflow_transaction_id = transactions.id OR r.outflow_transaction_id = transactions.id
        )
      SQL

      transaction do
        execute(<<~SQL.squish)
          UPDATE transactions SET transfer_id = NULL, updated_at = NOW()
          WHERE transfer_id IN (#{quoted_list(loser_ids)})
        SQL

        execute("DELETE FROM transfers WHERE id IN (#{quoted_list(loser_ids)})")

        if kind_reset_ids.any?
          execute(<<~SQL.squish)
            UPDATE transactions SET kind = 'standard', updated_at = NOW()
            WHERE id IN (#{quoted_list(kind_reset_ids)})
              AND kind IN (#{quoted_list(TRANSFER_KINDS)})
              AND #{unreferenced}
          SQL
        end

        if freed_ids.any?
          execute(<<~SQL.squish)
            UPDATE entries SET idempotency_key = NULL
            FROM transactions
            WHERE entries.entryable_type = 'Transaction'
              AND entries.entryable_id = transactions.id
              AND transactions.id IN (#{quoted_list(freed_ids)})
              AND entries.idempotency_key IS NOT NULL
              AND #{unreferenced}
          SQL
        end

        rederive_kept_transfer_kinds(rederive_ids) if rederive_ids.any?

        # Family#entries_cache_version reads entries.updated_at, so cached
        # reports pick up the changed kinds and transfers.
        execute(<<~SQL.squish)
          UPDATE entries SET updated_at = NOW()
          WHERE entryable_type = 'Transaction' AND entryable_id IN (#{quoted_list(touched_ids)})
        SQL
      end
    end

    # Sets both legs of the kept transfers to the kinds Transfer#confirm!
    # gives them (a copy of Transfer.kind_for_account, so this migration does
    # not change with the model): inflow funds_movement, outflow by the
    # destination account.
    def rederive_kept_transfer_kinds(transfer_ids)
      execute(<<~SQL.squish)
        UPDATE transactions SET kind = 'funds_movement', updated_at = NOW()
        FROM transfers tr
        WHERE tr.id IN (#{quoted_list(transfer_ids)}) AND transactions.id = tr.inflow_transaction_id
      SQL

      execute(<<~SQL.squish)
        UPDATE transactions SET kind = CASE
            WHEN dest.accountable_type = 'Loan' THEN 'loan_payment'
            WHEN dest.accountable_type = 'CreditCard' THEN 'cc_payment'
            WHEN dest.accountable_type IN ('Investment', 'Crypto') THEN
              CASE WHEN src.accountable_type IN ('Investment', 'Crypto') THEN 'funds_movement' ELSE 'investment_contribution' END
            WHEN dest.classification = 'liability' THEN 'cc_payment'
            ELSE 'funds_movement'
          END,
          updated_at = NOW()
        FROM transfers tr
        JOIN entries inflow_entry ON inflow_entry.entryable_type = 'Transaction' AND inflow_entry.entryable_id = tr.inflow_transaction_id
        JOIN accounts dest ON dest.id = inflow_entry.account_id
        JOIN entries outflow_entry ON outflow_entry.entryable_type = 'Transaction' AND outflow_entry.entryable_id = tr.outflow_transaction_id
        JOIN accounts src ON src.id = outflow_entry.account_id
        WHERE tr.id IN (#{quoted_list(transfer_ids)}) AND transactions.id = tr.outflow_transaction_id
      SQL
    end

    def valid_index?(name, unique:)
      select_value(<<~SQL.squish) == true
        SELECT i.indisvalid AND i.indisunique = #{unique ? "TRUE" : "FALSE"}
        FROM pg_index i
        WHERE i.indexrelid = to_regclass(#{connection.quote(name)})
      SQL
    end

    def quoted_list(ids)
      ids.map { |id| connection.quote(id) }.join(", ")
    end
end
