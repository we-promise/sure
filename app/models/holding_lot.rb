# A parcel of one security in one account. A derived lot is acquired by a
# trade (its source entry), which owns its quantity and date. The opening lot
# holds the units no imported trade accounts for. Lots are written by the
# holdings materializer from the calculators' lot books.
class HoldingLot < ApplicationRecord
  belongs_to :account
  belongs_to :security
  belongs_to :source_entry, class_name: "Entry", optional: true
  belongs_to :origin_security, class_name: "Security", optional: true

  scope :derived, -> { where.not(source_entry_id: nil) }
  scope :opening, -> { where(source_entry_id: nil) }

  def opening?
    source_entry_id.nil?
  end

  class << self
    # Replaces an account's lots with `rows`, within `security_ids` when given,
    # keeping each lot's row (and id) by its key: the source entry for a derived
    # lot, the position for the opening lot. An opening lot keeps its origin.
    # A caller that cannot see opening lots (`openings: false`) leaves them be.
    def store!(account, rows, security_ids: nil, openings: true)
      rows = rows.select { |row| security_ids.include?(row[:security_id]) } if security_ids
      derived_rows, opening_rows = rows.partition { |row| row[:source_entry_id] }
      scope = account.holding_lots
      scope = scope.where(security_id: security_ids) if security_ids

      transaction do
        scope.derived.where.not(source_entry_id: derived_rows.pluck(:source_entry_id)).delete_all
        scope.opening.where.not(security_id: opening_rows.pluck(:security_id)).delete_all if openings
        if derived_rows.any?
          upsert_all(derived_rows, unique_by: %i[account_id source_entry_id],
            update_only: %i[security_id acquired_on qty unit_cost currency], touch: true)
        end
        if opening_rows.any?
          upsert_all(opening_rows, unique_by: :index_holding_lots_one_opening_lot_per_position,
            update_only: %i[qty unit_cost currency clamped], touch: true)
        end
      end
    end

    # Moves lots to another security with their trades. Lots are never merged:
    # derived lots keep their own rows, and an opening lot moves only where the
    # target has none, since the target's own is restated over the moved units
    # at the next materialization.
    def move!(derived:, opening:, to:)
      derived.update_all(security_id: to.id, updated_at: Time.current)
      opening.find_each do |lot|
        if where(account_id: lot.account_id, security_id: to.id).opening.exists?
          lot.delete
        else
          lot.update_columns(security_id: to.id, updated_at: Time.current)
        end
      end
    end
  end
end
