class AddOriginalQuantityToHoldingLots < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:holding_lots, :original_quantity)
      add_column :holding_lots, :original_quantity, :decimal, precision: 34, scale: 18
      add_check_constraint :holding_lots, "original_quantity >= 0", name: "holding_lots_original_quantity_non_negative"
    end

    HoldingLot.reset_column_information

    HoldingLot.where(source_entry_id: nil, clamped: false).find_each do |hl|
      orig_qty = reconstruct_original_quantity(hl)
      hl.update_columns(original_quantity: orig_qty)
    end
  end

  def down
    remove_check_constraint :holding_lots, name: "holding_lots_original_quantity_non_negative"
    remove_column :holding_lots, :original_quantity
  end

  private

    def reconstruct_original_quantity(hl)
      account = hl.account
      security_id = hl.security_id
      return [ hl.qty.to_d, BigDecimal("0") ].max unless account

      sales = Entry.joins("JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
                   .where(account_id: account.id)
                   .where("trades.security_id = ?", security_id)
                   .where("trades.qty < 0")
                   .order(Arel.sql("entries.date ASC, entries.created_at ASC, entries.id ASC"))
                   .includes(:entryable)

      opening_consumed = BigDecimal("0")
      opening_depleted = false

      sales.each do |sale|
        break if opening_depleted

        disposals = HoldingLotDisposal.where(sale_entry_id: sale.id)
        nil_disposals = disposals.where(lot_source_entry_id: nil)
        has_buy_disposals = disposals.where.not(lot_source_entry_id: nil).exists?

        if nil_disposals.exists?
          qty = nil_disposals.sum(:qty)
          factor = split_factor_between(security_id, sale.date, Date.current)
          scaled_qty = factor == 1 ? qty : Security::Split.scale(qty, factor)
          opening_consumed += scaled_qty
        end

        opening_depleted = true if has_buy_disposals
      end

      [ hl.qty.to_d + opening_consumed, hl.qty.to_d, BigDecimal("0") ].max
    end

    def split_factor_between(security_id, from, to)
      return Rational(1) if from.nil? || to.nil? || from >= to

      Security::Split.where(security_id: security_id)
                     .where("ex_date > ? AND ex_date <= ?", from, to)
                     .order(:ex_date)
                     .reduce(Rational(1)) { |factor, split| factor * split.ratio }
    end
end
