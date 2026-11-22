# ResetKindsOfPendingTransferMatches returned every pending auto-match to the
# standard kind, so unconfirmed transfers counted as both income and spending.
# Pending matches take their transfer kinds again unless the family confirms
# matches first (require_transfer_match_confirmation, off by default), so give
# them back to every pending match whose legs are still both standard
# (Transfer#standard_legs?). A pending transfer with kinds of its own predates
# the match's kinds, so it keeps them.
class RestoreKindsOfPendingTransferMatches < ActiveRecord::Migration[8.1]
  def up
    Family.reset_column_information
    Transfer.reset_column_information

    Family.where(require_transfer_match_confirmation: false).find_each do |family|
      family.pending_transfer_matches.find_each do |transfer|
        transfer.apply_kinds! if transfer.standard_legs?
      end
    end
  end

  # Transfer#reject! and Family#update_transfer_match_confirmation! reset the
  # kinds again where needed.
  def down
  end
end
