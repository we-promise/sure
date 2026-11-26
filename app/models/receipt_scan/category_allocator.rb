# Groups a receipt's line items by the category the model assigned them, into amounts that add
# up exactly to the receipt total, ready to become the parts of a split transaction.
class ReceiptScan::CategoryAllocator
  # Groups smaller than this share of the total, in size, join the largest group, so a carrier bag doesn't
  # become its own split.
  FOLD_SHARE = BigDecimal("0.05")

  # precision: the currency's decimal places, which the parts are rounded to.
  def initialize(extraction, categories:, precision: 2)
    @extraction = extraction
    @precision = precision
    @categories_by_name = categories.index_by { |category| category.name.downcase }
  end

  # @return [Array<Hash>] { category: Category|nil, amount: BigDecimal, item_names: [String] },
  #   largest first, amounts summing to the receipt total
  def groups
    return [] if total.nil?

    nets = extraction.line_items.map { |item| [ item, decimal(item["amount"]) - decimal(item["discount"]) ] }
    items_total = nets.sum { |_, net| net }
    # Items are scaled to the total, so a refund read with positive lines still splits.
    return [ group(nil, total, []) ] if items_total.zero?

    grouped = nets.group_by { |item, _| category_for(item["category_name"]) }.map do |category, rows|
      group(category, rows.sum { |_, net| net * total / items_total }.round(precision), rows.map { |item, _| item["name"] })
    end

    grouped = fold_small(grouped.sort_by { -_1[:amount].abs })
    settle_rounding(grouped)
  end

  private
    attr_reader :extraction, :categories_by_name, :precision

    def total
      extraction.total
    end

    def category_for(name)
      categories_by_name[name.to_s.downcase] if name.present?
    end

    def fold_small(groups)
      largest, *rest = groups
      kept = rest.reject do |candidate|
        next false if candidate[:amount].abs >= FOLD_SHARE * total.abs

        largest[:amount] += candidate[:amount]
        largest[:item_names] += candidate[:item_names]
        true
      end
      [ largest, *kept ]
    end

    # Rounding each group to the currency's smallest unit can leave the sum a few units off the
    # total. A shortfall goes to the largest group; an excess comes off the largest groups a unit
    # at a time, so no group crosses zero. A group left at zero joins the largest.
    def settle_rounding(groups)
      cent = BigDecimal("1e-#{precision}") * (total.negative? ? -1 : 1)
      missing = ((total - groups.sum { _1[:amount] }) / cent).round
      if missing >= 0
        groups.first[:amount] += cent * missing
      else
        (-missing).times { groups.max_by { _1[:amount].abs }[:amount] -= cent }
      end

      largest, *rest = groups.sort_by { -_1[:amount].abs }
      kept = rest.reject do |candidate|
        next false if candidate[:amount].nonzero?

        largest[:item_names] += candidate[:item_names]
        true
      end
      [ largest, *kept ]
    end

    def group(category, amount, item_names)
      { category:, amount:, item_names: }
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end
end
