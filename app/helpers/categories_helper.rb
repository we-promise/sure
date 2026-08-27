module CategoriesHelper
  def trade_category
    Category.new \
      name: I18n.t("categories.virtual.trade"),
      color: Category::TRADE_COLOR
  end

  def family_categories
    [ Category.uncategorized ].concat(Current.family.categories.alphabetically_by_hierarchy)
  end
end
