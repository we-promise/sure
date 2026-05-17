module ImportsHelper
  def mapping_label(mapping_class)
    {
      "Import::AccountTypeMapping" => I18n.t("imports.mapping_labels.account_type"),
      "Import::AccountMapping" => I18n.t("imports.mapping_labels.account"),
      "Import::CategoryMapping" => I18n.t("imports.mapping_labels.category"),
      "Import::TagMapping" => I18n.t("imports.mapping_labels.tag")
    }.fetch(mapping_class.name)
  end

  def import_col_label(key)
    {
      date: I18n.t("imports.column_labels.date"),
      amount: I18n.t("imports.column_labels.amount"),
      name: I18n.t("imports.column_labels.name"),
      currency: I18n.t("imports.column_labels.currency"),
      category: I18n.t("imports.column_labels.category"),
      tags: I18n.t("imports.column_labels.tags"),
      account: I18n.t("imports.column_labels.account"),
      notes: I18n.t("imports.column_labels.notes"),
      qty: I18n.t("imports.column_labels.qty"),
      ticker: I18n.t("imports.column_labels.ticker"),
      exchange: I18n.t("imports.column_labels.exchange"),
      price: I18n.t("imports.column_labels.price"),
      entity_type: I18n.t("imports.column_labels.entity_type"),
      category_parent: I18n.t("imports.column_labels.category_parent"),
      category_color: I18n.t("imports.column_labels.category_color"),
      category_icon: I18n.t("imports.column_labels.category_icon")
    }[key]
  end

  def dry_run_resource(key)
    map = {
      transactions: DryRunResource.new(label: "Transactions", icon: "credit-card", text_class: "text-cyan-500", bg_class: "bg-cyan-500/5"),
      accounts: DryRunResource.new(label: "Accounts", icon: "layers", text_class: "text-orange-500", bg_class: "bg-orange-500/5"),
      categories: DryRunResource.new(label: "Categories", icon: "shapes", text_class: "text-blue-500", bg_class: "bg-blue-500/5"),
      tags: DryRunResource.new(label: "Tags", icon: "tags", text_class: "text-violet-500", bg_class: "bg-violet-500/5"),
      rules: DryRunResource.new(label: "Rules", icon: "workflow", text_class: "text-green-500", bg_class: "bg-green-500/5"),
      merchants: DryRunResource.new(label: "Merchants", icon: "store", text_class: "text-amber-500", bg_class: "bg-amber-500/5"),
      trades: DryRunResource.new(label: "Trades", icon: "arrow-left-right", text_class: "text-emerald-500", bg_class: "bg-emerald-500/5"),
      valuations: DryRunResource.new(label: "Valuations", icon: "trending-up", text_class: "text-pink-500", bg_class: "bg-pink-500/5"),
      budgets: DryRunResource.new(label: "Budgets", icon: "wallet", text_class: "text-indigo-500", bg_class: "bg-indigo-500/5"),
      budget_categories: DryRunResource.new(label: "Budget Categories", icon: "pie-chart", text_class: "text-teal-500", bg_class: "bg-teal-500/5")
    }

    map[key]
  end

  def permitted_import_configuration_path(import)
    if permitted_import_types.include?(import.type.underscore)
      "import/configurations/#{import.type.underscore}"
    else
      raise "Unknown import type: #{import.type}"
    end
  end

  def cell_class(row, field)
    base = "bg-container text-sm focus:ring-gray-900 theme-dark:focus:ring-gray-100 focus:border-solid w-full max-w-full disabled:text-subdued"

    row.valid? # populate errors

    border = row.errors.key?(field) ? "border-destructive" : "border-transparent"

    [ base, border ].join(" ")
  end

  def cell_is_valid?(row, field)
    row.valid? # populate errors
    !row.errors.key?(field)
  end

  private
    def permitted_import_types
      %w[transaction_import trade_import account_import mint_import category_import rule_import]
    end

    DryRunResource = Struct.new(:label, :icon, :text_class, :bg_class, keyword_init: true)
end
