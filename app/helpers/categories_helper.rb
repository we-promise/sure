module CategoriesHelper
  def transfer_category
    Category.new \
      name: I18n.t("categories.virtual.transfer"),
      color: Category::TRANSFER_COLOR,
      lucide_icon: "arrow-right-left"
  end

  def payment_category
    Category.new \
      name: I18n.t("categories.virtual.payment"),
      color: Category::PAYMENT_COLOR,
      lucide_icon: "arrow-right"
  end

  def trade_category
    Category.new \
      name: I18n.t("categories.virtual.trade"),
      color: Category::TRADE_COLOR
  end

  def family_categories
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically_by_hierarchy)
  end

  # Transactions keep a real, editable category (nil when none is chosen).
  # For transfers with no category picked, show the Transfer/Payment badge
  # instead of the generic Uncategorized one, so the row still visually
  # reads as a transfer rather than "needs categorizing."
  def display_category_for(transaction)
    return transaction.category if transaction.category
    return transaction.transfer.payment? ? payment_category : transfer_category if transaction.transfer

    Category.uncategorized
  end
end
