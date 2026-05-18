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
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically)
  end
end
