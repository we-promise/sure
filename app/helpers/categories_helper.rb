module CategoriesHelper
  def transfer_category
    Category.new \
      name: "Transfer",
      color: Category::TRANSFER_COLOR,
      lucide_icon: "arrow-right-left"
  end

  def payment_category
    Category.new \
      name: "Payment",
      color: Category::PAYMENT_COLOR,
      lucide_icon: "arrow-right"
  end

  def trade_category
    Category.new \
      name: "Trade",
      color: Category::TRADE_COLOR
  end

  def family_categories
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically)
  end

  # Build sorted category options for combobox: parents first, then children alphabetically
  def sorted_category_options(categories)
    categories
      .select { |cat| cat.parent_id.nil? }
      .sort_by(&:name)
      .flat_map { |parent| [parent] + parent.subcategories.sort_by(&:name) }
      .map(&:to_combobox_option)
  end
end
