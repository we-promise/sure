# Removes what a FinanceKit connection imported, for a family that disconnected
# with disposition "discard".
#
# Irreversible, and deliberately thorough: everything the publisher put into the
# ledger goes, including entries the family later reconciled, excluded or edited.
# A partial deletion would be worse than none, because the family was told their
# data was removed.
#
# Two things survive, and both are deliberate. The connection row itself stays as
# a revoked receipt -- it holds no financial values, and the batch receipts beside
# it already had their payloads dropped at revocation. And a lineage another
# active connection still publishes into is left entirely alone: during a device
# replacement window two items reference one lineage, and one of them disconnecting
# must not delete the other's live accounts.
class Financekit::Purge
  COUNT_KEYS = %w[accounts_destroyed accounts_emptied entries identities observations conflicts
    lineages_skipped].freeze

  def initialize(item)
    @item = item
  end

  def perform!
    counts = COUNT_KEYS.index_with(0)
    @item.financekit_account_lineages.distinct.find_each do |lineage|
      next counts["lineages_skipped"] += 1 if lineage.other_active_writer_than?(@item)
      next if lineage.discarded?

      purge_lineage!(lineage, counts)
    end
    @item.update!(purge_completed_at: Time.current)
    Financekit::Diagnostics.capture(item: @item, source: self.class.name,
      message: "FinanceKit imported data discarded", event: "purge_completed", counts: counts)
    counts
  rescue StandardError => error
    # purge_completed_at stays nil, so the sweep in FinancekitInboxJob tries
    # again. Re-raised so the job's own retry sees it too: a deletion the family
    # asked for should not be dropped on the floor quietly.
    Financekit::Diagnostics.capture(item: @item, source: self.class.name, level: "error",
      message: "FinanceKit discard failed", event: "purge_failed", error_class: error.class.name)
    raise
  end

  private

    def purge_lineage!(lineage, counts)
      account = lineage.account
      # One transaction per lineage rather than one for the whole connection: a
      # family with several wallet accounts should not lose a completed account's
      # deletion because a later one failed, and the sweep resumes from whatever
      # is left.
      FinancekitAccountLineage.transaction do
        empty_or_destroy_account!(account, lineage, counts) if account
        counts["conflicts"] += FinancekitConflict.where(financekit_account_lineage_id: lineage.id).destroy_all.size
        counts["identities"] += lineage.financekit_transactions.destroy_all.size
        counts["observations"] += lineage.financekit_balance_observations.destroy_all.size
        # account is nulled so a later enrollment cannot resurrect the link to an
        # account this lineage no longer describes, and the row stays as the
        # record that this source was discarded rather than merely unlinked.
        lineage.update!(status: FinancekitAccountLineage::DISCARDED, account: nil)
      end
    end

    def empty_or_destroy_account!(account, lineage, counts)
      unless lineage.account_created_by_provider?
        counts["entries"] += destroy_imported_entries!(account)
        counts["accounts_emptied"] += 1
        # The canonical balance came from a booked observation that no longer
        # exists. Sync recomputes it from the entries that remain, which for a
        # linked account is the history the family had before FinanceKit arrived.
        account.sync_later
        return
      end

      counts["entries"] += account.entries.count
      account.destroy!
      counts["accounts_destroyed"] += 1
    end

    # Entries carry source "financekit" whether the publisher created them or
    # claimed a manual entry that matched. Both are removed: the family asked for
    # the import to be undone, and a claimed entry's amount and date came from
    # the publisher even when the row did not.
    #
    # Destroyed one at a time rather than deleted in bulk because an entry's
    # entryable is reachable only through Active Record: nothing in the database
    # points from a transactions row back to its entry. A bulk delete leaves the
    # Transaction standing, and with it any Transfer the entry was part of and
    # that transfer's fee transactions. Destroying the entry takes the whole chain
    # and leaves the counterpart entry in place, unlinked -- which is the
    # behaviour the disconnect tests pin.
    #
    # Split children are the exception that needs no help here: entries.parent_entry_id
    # cascades in the database, so they would go either way.
    def destroy_imported_entries!(account)
      destroyed = 0
      account.entries.where(source: "financekit").find_each do |entry|
        entry.destroy!
        destroyed += 1
      end
      destroyed
    end
end
