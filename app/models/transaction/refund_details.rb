# Refund metadata shared by API and assistant responses. Resolve links in batches
# and restrict both directions to the caller's accessible accounts.
class Transaction::RefundDetails
  def initialize(transactions:, user:)
    @transactions = transactions.to_a
    visible = user.family.transactions.joins(:entry)
      .where(entries: { account_id: user.accessible_accounts.select(:id) })
    @visible_purchase_ids = visible.where(id: @transactions.filter_map(&:refund_of_id)).pluck(:id).to_set
    @refunds = visible.where(refund_of_id: @transactions.map(&:id))
      .includes(:entry).group_by(&:refund_of_id)
  end

  def for(transaction)
    entry = transaction.entry
    refunds = @refunds.fetch(transaction.id, [])
    cost = nil
    status = "not_applicable"
    if transaction.standard? && entry.amount.positive? && !entry.excluded?
      begin
        money = transaction.purchase_net_cost_money(refunds: refunds)
        cost = {
          amount: money.amount.to_s("F"), currency: money.currency.iso_code,
          amount_cents: (money.amount * money.currency.minor_unit_conversion).round.to_i
        }
        status = "available"
      rescue Money::ConversionError
        status = "exchange_rate_missing"
      end
    end

    {
      kind: transaction.kind,
      refund: transaction.refund?,
      reporting_classification: transaction.refund? ? "expense" : entry.classification,
      cash_flow_direction: entry.amount.negative? ? "inflow" : "outflow",
      refund_of_transaction_id: @visible_purchase_ids.include?(transaction.refund_of_id) ? transaction.refund_of_id : nil,
      refund_transaction_ids: refunds.map(&:id),
      net_purchase_cost: cost,
      net_purchase_cost_status: status
    }
  end
end
