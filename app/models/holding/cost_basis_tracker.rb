# The pre-lot weighted-average tracker's name, kept only as the subject of the
# parity suite: cost_basis_tracker_test.rb and the oracle block in
# lot_book_test.rb assert Holding::LotBook reproduces its figures to the last
# digit. No production code constructs it — the calculators use LotBook
# directly. The alias and its parity tests go away with #4501, the series'
# last PR, once no reader can still be running old code.
class Holding::CostBasisTracker < Holding::LotBook
end
