class UI::Dashboard::BondSummaryRow < ApplicationComponent
  attr_reader :account, :lot, :show_border

  def initialize(account:, lot:, show_border: false)
    @account = account
    @lot = lot
    @show_border = show_border
  end

  def subtype_label
    Bond.long_subtype_label_for(lot.subtype) || t("bonds.purchase_holding.unknown")
  end

  def total_return_amount
    @total_return_amount ||= if projected_total_return?
      lot.projected_total_return_amount(allow_import: false)
    else
      lot.total_return_amount(allow_import: false)
    end
  end

  def total_return_label
    if projected_total_return?
      t("bonds.purchase_holding.projected_to_maturity")
    else
      t("bonds.purchase_holding.since_purchase")
    end
  end

  def total_return_class
    total_return_amount.negative? ? "text-destructive" : "text-success"
  end

  def rate_text
    if lot.inflation_linked?
      return t("bonds.purchase_holding.update_needed") if lot.requires_rate_review?

      current_rate = lot.current_rate_percent(allow_import: false)
      return helpers.number_to_percentage(current_rate, precision: 3) if current_rate.present?

      t("bonds.purchase_holding.unknown")
    else
      lot.interest_rate.present? ? helpers.number_to_percentage(lot.interest_rate, precision: 3) : t("bonds.purchase_holding.unknown")
    end
  end

  def rate_meta
    if lot.inflation_linked?
      inflation_linked_rate_meta
    else
      t(
        "bonds.purchase_holding.bond_meta",
        rate_type: localized_rate_type,
        coupon: localized_coupon_frequency
      )
    end
  end

  def row_classes
    classes = [ "text-sm", "font-medium", "text-primary" ]
    classes << "border-b border-divider" if show_border
    classes.join(" ")
  end

  private
    def projected_total_return?
      lot.total_return_amount(allow_import: false).abs < 0.01.to_d && lot.projected_total_return_amount(allow_import: false).positive?
    end

    def inflation_linked_rate_meta
      return t("bonds.purchase_holding.pending_review") if lot.requires_rate_review?

      inflation_component = lot.current_inflation_component_percent(allow_import: false)
      margin_component = lot.current_margin_percent(allow_import: false)
      return t("bonds.purchase_holding.first_period_fixed_rate") if inflation_component.nil? || margin_component.nil?

      inflation = helpers.number_to_percentage(inflation_component.to_d, precision: 3)
      margin = helpers.number_to_percentage(margin_component.to_d, precision: 3)

      if lot.gus_inflation_source?(allow_import: false)
        t(
          "bonds.purchase_holding.inflation_meta_gus",
          inflation: inflation,
          margin: margin,
          indicator: lot.current_inflation_indicator_id
        )
      elsif current_inflation_source_key.blank? || current_inflation_source_key == "manual"
        t(
          "bonds.purchase_holding.inflation_meta_manual",
          inflation: inflation,
          margin: margin
        )
      else
        t(
          "bonds.purchase_holding.inflation_meta_provider",
          inflation: inflation,
          margin: margin,
          provider: localized_inflation_provider
        )
      end
    end

    def current_inflation_source_key
      lot.current_inflation_source(allow_import: false).to_s.presence
    end

    def localized_inflation_provider
      provider = current_inflation_source_key
      return t("bonds.purchase_holding.unknown") if provider.blank?

      t("bonds.purchase_holding.inflation_providers.#{provider}", default: provider.to_s.humanize)
    end

    def localized_rate_type
      return t("bonds.purchase_holding.unknown") if lot.rate_type.blank?

      t("bond_lots.form.rate_types.#{lot.rate_type}", default: t("bonds.purchase_holding.unknown"))
    end

    def localized_coupon_frequency
      return t("bonds.purchase_holding.unknown") if lot.coupon_frequency.blank?

      t("bond_lots.form.coupon_frequencies.#{lot.coupon_frequency}", default: t("bonds.purchase_holding.unknown"))
    end
end
