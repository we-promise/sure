# ResetKindsOfPendingTransferMatches returned every pending auto-match to the
# standard kind, so unconfirmed transfers counted as both income and spending.
# Pending matches take their transfer kinds again unless the family confirms
# matches first (require_transfer_match_confirmation, off by default), so give
# them back to every pending match whose legs carry nothing but what the match
# set (Transfer#match_kinds_only?).
class RestoreKindsOfPendingTransferMatches < ActiveRecord::Migration[8.1]
  def up
    Family.reset_column_information

    Family.where(require_transfer_match_confirmation: false).find_each do |family|
      family.pending_transfer_matches.find_each do |transfer|
        transfer.apply_kinds! if transfer.match_kinds_only?
      end
    end
  end

  # Transfer#reject! and Family#update_transfer_match_confirmation! reset the
  # kinds again where needed.
  def down
  end
end
