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
      category_icon: I18n.t("imports.column_labels.category_icon"),
      merchant_color: I18n.t("imports.column_labels.merchant_color"),
      merchant_website: I18n.t("imports.column_labels.merchant_website")
    }[key]
  end

  def dry_run_resource(key)
    map = {
      transactions: DryRunResource.new(label: t("imports.dry_run_resources.transactions"), icon: "credit-card", text_class: "text-info", bg_class: "bg-info/10"),
      balances: DryRunResource.new(label: t("imports.dry_run_resources.balances"), icon: "line-chart", text_class: "text-secondary", bg_class: "bg-container-inset"),
      accounts: DryRunResource.new(label: t("imports.dry_run_resources.accounts"), icon: "layers", text_class: "text-warning", bg_class: "bg-warning/10"),
      categories: DryRunResource.new(label: t("imports.dry_run_resources.categories"), icon: "shapes", text_class: "text-info", bg_class: "bg-info/10"),
      tags: DryRunResource.new(label: t("imports.dry_run_resources.tags"), icon: "tags", text_class: "text-info", bg_class: "bg-info/10"),
      rules: DryRunResource.new(label: t("imports.dry_run_resources.rules"), icon: "workflow", text_class: "text-success", bg_class: "bg-success/10"),
      merchants: DryRunResource.new(label: t("imports.dry_run_resources.merchants"), icon: "store", text_class: "text-warning", bg_class: "bg-warning/10"),
      recurring_transactions: DryRunResource.new(label: t("imports.dry_run_resources.recurring_transactions"), icon: "repeat-2", text_class: "text-secondary", bg_class: "bg-container-inset"),
      transfers: DryRunResource.new(label: t("imports.dry_run_resources.transfers"), icon: "repeat", text_class: "text-secondary", bg_class: "bg-container-inset"),
      rejected_transfers: DryRunResource.new(label: t("imports.dry_run_resources.rejected_transfers"), icon: "ban", text_class: "text-destructive", bg_class: "bg-destructive/10"),
      trades: DryRunResource.new(label: t("imports.dry_run_resources.trades"), icon: "arrow-left-right", text_class: "text-success", bg_class: "bg-success/10"),
      holdings: DryRunResource.new(label: t("imports.dry_run_resources.holdings"), icon: "briefcase-business", text_class: "text-secondary", bg_class: "bg-container-inset"),
      valuations: DryRunResource.new(label: t("imports.dry_run_resources.valuations"), icon: "trending-up", text_class: "text-info", bg_class: "bg-info/10"),
      budgets: DryRunResource.new(label: t("imports.dry_run_resources.budgets"), icon: "wallet", text_class: "text-info", bg_class: "bg-info/10"),
      budget_categories: DryRunResource.new(label: t("imports.dry_run_resources.budget_categories"), icon: "pie-chart", text_class: "text-success", bg_class: "bg-success/10")
    }

    map[key]
  end

  def import_verification_view(import)
    ImportVerificationView.new(import.verification_payload)
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
      %w[transaction_import trade_import account_import mint_import actual_import ynab_import category_import rule_import merchant_import]
    end

    DryRunResource = Struct.new(:label, :icon, :text_class, :bg_class, keyword_init: true)

    ImportVerificationView = Struct.new(:payload) do
      def status
        readback.fetch("status", "not_verified").to_s
      end

      def checked_total
        checked_counts.values.sum(&:to_i)
      end

      def checked_counts
        hash_value(readback["checked_counts"])
      end

      def mismatches
        hash_value(readback["mismatches"])
      end

      def mismatches_count
        mismatches.size
      end

      def mismatches_preview
        mismatches.first(3)
      end

      def mismatches?
        mismatches.any?
      end

      private
        def readback
          hash_value(payload_hash["readback"])
        end

        def payload_hash
          hash_value(payload)
        end

        def hash_value(value)
          return {} unless value.respond_to?(:to_h)

          value.to_h.deep_stringify_keys
        end
    end
end
