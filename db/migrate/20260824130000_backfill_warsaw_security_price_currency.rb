# frozen_string_literal: true

class BackfillWarsawSecurityPriceCurrency < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def up
    say_with_time "Backfilling Warsaw security_prices USD → PLN (and WAR → XWAR MICs)" do
      result = Security::WarsawPriceCurrencyBackfill.new(dry_run: false, sync_accounts: true).call
      say(
        "scanned=#{result.securities_scanned} " \
        "mics=#{result.mics_canonicalized} " \
        "relabeled=#{result.prices_relabeled} " \
        "deleted_usd_dupes=#{result.prices_deleted} " \
        "accounts_synced=#{result.accounts_queued_for_sync}",
        true
      )
      result.prices_relabeled + result.prices_deleted + result.mics_canonicalized
    end
  end

  def down
    # Irreversible: cannot distinguish corrected PLN rows from prices that were
    # always correctly stored as PLN.
  end
end
