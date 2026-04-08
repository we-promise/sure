class PurchaseHoldingPresenter
  attr_reader :lot, :account, :view

  def initialize(lot:, account:, view:)
    @lot = lot
    @account = account
    @view = view
  end

  def label
    Bond.long_subtype_label_for(lot.subtype) || t("bonds.purchase_holding.unknown")
  end

  def weight
    total_balance = account.balance.to_d
    return 0 if total_balance.zero?

    current_value = lot.estimated_current_value(allow_import: false)
    (current_value.to_d / total_balance) * 100
  end

  def total_return_amount
    @total_return_amount ||= projected_total_return? ? lot.projected_total_return_amount(allow_import: false) : lot.total_return_amount(allow_import: false)
  end

  def total_return_percent
    @total_return_percent ||= projected_total_return? ? lot.projected_total_return_percent(allow_import: false) : lot.total_return_percent(allow_import: false)
  end

  def return_label
    projected_total_return? ? t("bonds.purchase_holding.projected_to_maturity") : t("bonds.purchase_holding.since_purchase")
  end

  def total_return_class
    total_return_amount.negative? ? "text-destructive" : "text-success"
  end

  def rate_text
    if lot.inflation_linked?
      return t("bonds.purchase_holding.update_needed") if lot.requires_rate_review?

      current_rate = lot.current_rate_percent(allow_import: false)
      return view.number_to_percentage(current_rate, precision: 3) if current_rate.present?

      t("bonds.purchase_holding.unknown")
    else
      lot.interest_rate.present? ? view.number_to_percentage(lot.interest_rate, precision: 3) : t("bonds.purchase_holding.unknown")
    end
  end

  def rate_meta
    lot.inflation_linked? ? inflation_meta : fixed_meta
  end

  private
    def t(key, **options)
      view.t(key, **options)
    end

    def projected_total_return?
      lot.total_return_amount(allow_import: false).abs < 0.01.to_d && lot.projected_total_return_amount(allow_import: false).positive?
    end

    def inflation_meta
      return t("bonds.purchase_holding.pending_review") if lot.requires_rate_review?

      inflation_component = lot.current_inflation_component_percent(allow_import: false)
      margin_component = lot.current_margin_percent(allow_import: false)

      if inflation_component.nil? || margin_component.nil?
        if lot.in_first_rate_period?
          return t("bonds.purchase_holding.first_period_fixed_rate")
        end

        reference_on = lot.current_cpi_reference_on
        reference = reference_on ? view.l(reference_on, format: t("bonds.purchase_holding.month_year_format")) : t("bonds.purchase_holding.unknown")
        return t("bonds.purchase_holding.inflation_data_unavailable", reference:)
      end

      inflation_text = view.number_to_percentage(inflation_component.to_d, precision: 3)
      margin_text = view.number_to_percentage(margin_component.to_d, precision: 3)
      inflation_source = lot.current_inflation_source(allow_import: false)

      if inflation_source == "gus_sdp"
        t("bonds.purchase_holding.inflation_meta_gus", inflation: inflation_text, margin: margin_text, indicator: lot.current_inflation_indicator_id)
      elsif inflation_source == "manual" || inflation_source.blank?
        t("bonds.purchase_holding.inflation_meta_manual", inflation: inflation_text, margin: margin_text)
      else
        provider = t("bonds.purchase_holding.inflation_providers.#{inflation_source}", default: inflation_source.to_s.humanize)
        t("bonds.purchase_holding.inflation_meta_provider", inflation: inflation_text, margin: margin_text, provider:)
      end
    end

    def fixed_meta
      rate_type = if lot.rate_type.present?
        t("bond_lots.form.rate_types.#{lot.rate_type}", default: t("bonds.purchase_holding.unknown"))
      else
        t("bonds.purchase_holding.unknown")
      end

      coupon = if lot.coupon_frequency.present?
        t("bond_lots.form.coupon_frequencies.#{lot.coupon_frequency}", default: t("bonds.purchase_holding.unknown"))
      else
        t("bonds.purchase_holding.unknown")
      end

      coupon_amount = lot.coupon_amount_per_period
      if coupon_amount.present?
        t("bonds.purchase_holding.bond_meta_with_coupon_amount", rate_type:, coupon:, coupon_amount: view.format_money(coupon_amount))
      else
        t("bonds.purchase_holding.bond_meta", rate_type:, coupon:)
      end
    end
end
