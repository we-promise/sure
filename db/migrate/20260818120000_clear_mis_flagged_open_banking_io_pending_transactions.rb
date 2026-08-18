class ClearMisFlaggedOpenBankingIoPendingTransactions < ActiveRecord::Migration[7.2]
  # OpenBankingIoEntry::Processor used to classify anything that was not literally "BOOK"
  # as pending, so booked rows carrying "OTHR" or no status at all were stamped
  # extra->'open_banking_io'->>'pending' = true. Those rows are eligible for the
  # stale-pending prune, which destroys the entry along with any category, merchant, notes
  # or splits the user attached to it.
  #
  # This must run before the corrected classifier ships: the new code will not re-stamp
  # them, but the existing stamps stay until they are cleared here.
  PENDING_STATUSES = %w[PDNG PENDING HOLD].freeze

  def up
    quoted = PENDING_STATUSES.map { |s| connection.quote(s) }.join(", ")

    execute <<~SQL.squish
      UPDATE transactions
      SET extra = jsonb_set(
        extra,
        '{open_banking_io,pending}',
        'false'::jsonb,
        false
      )
      WHERE extra -> 'open_banking_io' ->> 'pending' = 'true'
        AND COALESCE(UPPER(TRIM(extra -> 'open_banking_io' ->> 'status')), '') NOT IN (#{quoted})
    SQL
  end

  def down
    # Irreversible by design: the previous stamps were wrong, and restoring them would
    # re-arm the prune that destroys the rows.
    raise ActiveRecord::IrreversibleMigration
  end
end
