Holding::HoldingData = Struct.new(
  :account_id, :security_id, :date,
  :qty, :price, :currency, :amount, :cost_basis,
  keyword_init: true
)
