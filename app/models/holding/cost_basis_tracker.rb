# Weighted-average cost basis for a single security. The behaviour lives in
# Holding::LotBook; this name keeps its interface (#apply, #buy, #sell, #split,
# #average_cost) available to code that only needs the average.
class Holding::CostBasisTracker < Holding::LotBook
end
