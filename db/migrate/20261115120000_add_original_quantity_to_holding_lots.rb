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
                   .where("entries.date <= ?", Date.current)
                   .where("trades.security_id = ?", security_id)
                   .where("trades.qty < 0")
                   .order(Arel.sql("entries.date ASC, entries.created_at ASC, entries.id ASC"))
                   .includes(:entryable)
                   .to_a

      disposals_by_sale = HoldingLotDisposal.where(sale_entry_id: sales.map(&:id)).group_by(&:sale_entry_id)
      splits = Security::Split.where(security_id: security_id, ex_date: ..Date.current).order(:ex_date).to_a

      opening_consumed = BigDecimal("0")
      opening_depleted = false

      sales.each do |sale|
        break if opening_depleted

        disposals = disposals_by_sale.fetch(sale.id, [])
        named_lot_id = sale.entryable&.lot_source_entry_id
        nil_qty = disposals.sum(BigDecimal("0")) { |d| d.lot_source_entry_id.nil? ? d.qty : BigDecimal("0") }
        # A disposal from a lot other than the sale's named lot means FIFO reached past the opening lot.
        unnamed_buy_disposal = disposals.any? { |d| d.lot_source_entry_id.present? && d.lot_source_entry_id != named_lot_id }

        if nil_qty.positive?
          factor = splits.reduce(Rational(1)) { |acc, split| split.ex_date > sale.date ? acc * split.ratio : acc }
          scaled_qty = factor == 1 ? nil_qty : Security::Split.scale(nil_qty, factor)
          opening_consumed += scaled_qty
        end

        opening_depleted = true if unnamed_buy_disposal
      end

      [ hl.qty.to_d + opening_consumed, hl.qty.to_d, BigDecimal("0") ].max
    end
end
