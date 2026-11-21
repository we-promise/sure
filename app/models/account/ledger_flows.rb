# The imported transactions and trades a balance reading had not seen yet.
class Account::LedgerFlows
  def initialize(account)
    @account = account
  end

  # Their sum through `date`, as entry amounts. Nil when that can't be judged:
  # the account isn't :cash, or a flow or the reading is in another currency.
  # With `before`, a later reading dated `date`, only flows that reading had
  # already seen count, so walking back through readings uses each flow once.
  def net_since(reading, date, before: nil)
    return unless account.balance_type == :cash
    return unless reading.currency == account.currency

    # Ignore entries the reading already included: its own timestamp is the watermark.
    # A split child inherits its parent's timestamp; the parent was the flow the reading
    # could have seen, and the child rows are created later by the split.
    flows = account.entries
      .excluding_pending
      .excluding_split_parents
      .where(date: reading.date..date)
      .where.not(entryable_type: "Valuation")
      .where(
        "entries.date > :reading_date OR " \
        "COALESCE((SELECT pe.created_at FROM entries pe WHERE pe.id = entries.parent_entry_id), entries.created_at) > :reading_written_at",
        reading_date: reading.date, reading_written_at: reading.updated_at
      )

    if before
      flows = flows.where(
        "entries.date < :later_date OR " \
        "COALESCE((SELECT pe.created_at FROM entries pe WHERE pe.id = entries.parent_entry_id), entries.created_at) <= :later_written_at",
        later_date: before.date, later_written_at: before.updated_at
      )
    end

    flows = flows.pluck(:currency, :amount)

    return unless flows.all? { |currency, _| currency == account.currency }

    flows.sum { |_, amount| amount }
  end

  private
    attr_reader :account
end
