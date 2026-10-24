# What one sale took from one lot, under a lot method (fifo). Written by the
# holdings materializer from the calculators' lot books; a sale's realized
# gain is read back from these rather than from the snapshot after it, which
# holds the cost of what remains.
class HoldingLotDisposal < ApplicationRecord
  belongs_to :account
  belongs_to :sale_entry, class_name: "Entry"
  belongs_to :lot_source_entry, class_name: "Entry", optional: true

  class << self
    # Replaces the disposals of the account's sales, within `security_ids`
    # when given. Scoped by the sales themselves, so a sale that moved to
    # another security is restated with it.
    def store!(account, rows, security_ids: nil)
      # A relation, not the association: the association's delete_all would
      # nullify account_id rather than delete.
      scope = where(account: account)
      if security_ids
        sales = account.entries.where(entryable_type: "Trade", entryable_id: Trade.where(security_id: security_ids).select(:id))
        scope = scope.where(sale_entry_id: sales.select(:id))
      end

      transaction do
        scope.delete_all
        insert_all(rows) if rows.any?
      end
    end

    # The stored disposals of each of `trades`, by sale entry id, for the
    # trades whose account sells by fifo and whose position's lots can be read
    # (HoldingLot.in_partition). Any other trade is absent, and reads its basis
    # from the holding snapshot as before. Expects each trade's entry and
    # account loaded.
    def readable_by_sale(trades)
      fifo = trades.select { |trade| trade.entry.account.cost_basis_fifo? }
      return {} if fifo.empty?

      readable = HoldingLot.in_partition(fifo.map { |trade| trade.entry.account_id }.uniq, fifo.map(&:security_id).uniq)
      sale_ids = fifo.select { |trade| readable.include?([ trade.entry.account_id, trade.security_id ]) }.map { |trade| trade.entry.id }
      return {} if sale_ids.empty?

      where(sale_entry_id: sale_ids).group_by(&:sale_entry_id)
    end
  end
end
