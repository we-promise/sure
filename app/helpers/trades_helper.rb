module TradesHelper
  # [label, id] pairs for a sale's lot picker. A lot reads the shares left in
  # it when the sale ran where Trade#lot_shares knows them, and its purchase
  # quantity otherwise.
  def lot_select_options(trade, lot_choices)
    lot_shares = trade.lot_shares(lot_choices)

    lot_choices.map do |lot|
      date = l(lot.date, format: :long)
      price = lot.trade.price_money.format
      shares = lot_shares[lot.id]
      label = if shares
        t("trades.show.lot_option_left", date: date, left: format_quantity(shares.left, exact: true), size: format_quantity(shares.size, exact: true), price: price)
      else
        t("trades.show.lot_option", date: date, qty: format_quantity(lot.trade.qty, exact: true), price: price)
      end
      [ label, lot.id ]
    end
  end
end
