# A parcel of one security in one account. A derived lot is acquired by a
# trade (its source entry), which owns its quantity and date. The opening lot
# holds the units no imported trade accounts for. Lots are written by the
# holdings materializer from the calculators' lot books.
class HoldingLot < ApplicationRecord
  belongs_to :account
  belongs_to :security
  belongs_to :source_entry, class_name: "Entry", optional: true
  belongs_to :origin_security, class_name: "Security", optional: true

  # A cost per unit is stored as a trade's price is, so it stays below 10^9.
  MAX_UNIT_COST = BigDecimal("1e9")

  scope :derived, -> { where.not(source_entry_id: nil) }
  scope :opening, -> { where(source_entry_id: nil) }

  validates :manual_total_cost, numericality: { greater_than_or_equal_to: 0, less_than: BigDecimal("1e15") }, allow_nil: true
  validate :manual_unit_cost_fits, if: :manual_total_cost

  def opening?
    source_entry_id.nil?
  end

  # What the user says the parcel cost when it was acquired, in the account's
  # currency. The calculators spread it over the acquiring trade's quantity,
  # so it holds through later splits and sales.
  def set_manual_total_cost!(total)
    update!(manual_total_cost: total)
  end

  def unlock_cost!
    update!(manual_total_cost: nil)
  end

  def manual_cost?
    !manual_total_cost.nil?
  end

  # The places the cost editor shows a saved total to: the currency's, or as
  # many as the column keeps when the total needs them, so saving the form
  # unchanged keeps it.
  def manual_total_cost_precision
    places = Money::Currency.new(currency).default_precision
    return places if manual_total_cost.nil? || manual_total_cost.round(places) == manual_total_cost

    self.class.columns_hash["manual_total_cost"].scale
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
            update_only: %i[security_id acquired_on qty unit_cost currency])
        end
        if opening_rows.any?
          upsert_all(opening_rows, unique_by: :index_holding_lots_one_opening_lot_per_position,
            update_only: %i[qty unit_cost currency clamped])
        end
      end
    end

    # The [account_id, security_id] pairs among those given whose stored lots
    # add up to the holding's quantity on its latest date. A forward sync keeps
    # opening lots it cannot rebuild, so after an unlink the lots can hold more
    # than the position, and a reader trusts them only where the two agree.
    def in_partition(account_ids, security_ids)
      lots = where(account_id: account_ids, security_id: security_ids).group(:account_id, :security_id).sum(:qty)
      return Set.new if lots.empty?

      holdings = Holding.where(account_id: account_ids, security_id: security_ids)
      latest = holdings.group(:account_id, :security_id).select(:account_id, :security_id, "MAX(date)")
      held = holdings.where("(holdings.account_id, holdings.security_id, holdings.date) IN (#{latest.to_sql})")
        .group(:account_id, :security_id).sum(:qty)

      lots.filter_map { |key, qty| key if held[key] == qty }.to_set
    end

    # Moves lots to another security with their trades. Derived lots keep
    # their own rows. An opening lot moved onto a position with its own is
    # merged into it: the quantities add, and the cost stays only where both
    # sides know it and agree, since one figure cannot stand for two
    # different ones. An opening lot with no units (a clamp records one) has
    # no cost to weigh, so it is dropped rather than merged. The merged lot
    # keeps the target's origin, so a reset does not split it apart again.
    def move!(derived:, opening:, to:)
      derived.update_all(security_id: to.id, updated_at: Time.current)
      opening.find_each do |lot|
        target = where(account_id: lot.account_id, security_id: to.id).opening.first
        if target && lot.qty.zero?
          lot.delete
        elsif target
          unit_cost = target.unit_cost if lot.unit_cost && lot.unit_cost == target.unit_cost
          target.update_columns(qty: target.qty + lot.qty, unit_cost: unit_cost, updated_at: Time.current)
          lot.delete
        else
          lot.update_columns(security_id: to.id, updated_at: Time.current)
        end
      end
    end
  end

  private
    # The calculators divide the total by the acquiring trade's quantity.
    def manual_unit_cost_fits
      qty = source_entry&.trade&.qty
      return unless qty&.positive?

      errors.add(:manual_total_cost, :less_than, count: MAX_UNIT_COST * qty) if manual_total_cost / qty >= MAX_UNIT_COST
    end
end
