# One day's figures of one part of an eToro account, as the day's last sync
# saw them: the positions the user opened (mirror_id 0) or a copy-trading
# mirror. eToro reports no past figures of a mirror, so these are the only
# record of its history, kept from the first sync that sees it, whatever the
# account is shown as (see EtoroAccount::CopiesProcessor).
#
# The total is what the part is worth: its uninvested cash (`cash`) and the
# amount and P&L of its open positions, CFDs included. The holdings are the
# real-asset positions by instrument ID, as { "units", "value" }. A mirror's
# deposits and withdrawals are what eToro's depositSummary and
# withdrawalSummary had added up to by then. A closed snapshot is the first
# day a mirror was no longer listed: it is worth nothing from then on.
class EtoroPortfolioSnapshot < ApplicationRecord
  OWN_POSITIONS = 0

  belongs_to :etoro_account

  validates :date, :mirror_id, :total, :cash, presence: true

  scope :own_positions, -> { where(mirror_id: OWN_POSITIONS) }
  scope :mirrors, -> { where.not(mirror_id: OWN_POSITIONS) }
  scope :chronological, -> { order(:date) }
end
