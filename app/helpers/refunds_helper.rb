module RefundsHelper
  def purchase_refund_details(transaction)
    visible_refunds = transaction.purchase_refunds
      .joins(:entry).where(entries: { account_id: Current.user.accessible_accounts.select(:id) })
      .includes(entry: :account).to_a
    purchase = transaction.refund_of
    purchase = nil if purchase && !Current.accessible_entries.exists?(id: purchase.entry.id)
    return if visible_refunds.empty? && !transaction.refund?

    net_cost = if visible_refunds.any?
      begin
        transaction.purchase_net_cost_money(refunds: visible_refunds)
      rescue Money::ConversionError
        nil
      end
    end
    { purchase: purchase, refunds: visible_refunds, net_cost: net_cost }
  end
end
