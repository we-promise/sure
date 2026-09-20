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
  # For funds_movement/cc_payment legs with no category picked, show the
  # Transfer/Payment badge: those kinds are excluded from the Uncategorized
  # bucket. Other kinds (loan_payment, investment_contribution) are counted as
  # Uncategorized, so they keep the Uncategorized badge to match the filter (#2592).
  def display_category_for(transaction)
    return transaction.category if transaction.category

    if Transaction::UNCATEGORIZED_EXCLUDED_KINDS.include?(transaction.kind) && transaction.transfer
      return transaction.transfer.payment? ? payment_category : transfer_category
    end

    Category.uncategorized
  end
end
