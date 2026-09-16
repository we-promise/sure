# `cost_basis_unknown` is not the same as a nil `cost_basis`. Nil means "this
# calculation produced nothing", and the materializer is right to leave an
# earlier figure standing. Unknown means "this position contains a transfer, so
# no cost basis can be known here" — a stale calculated figure has to go.
Holding::HoldingData = Struct.new(
  :account_id, :security_id, :date,
  :qty, :price, :currency, :amount, :cost_basis, :cost_basis_unknown,
  keyword_init: true
)
