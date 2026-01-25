module InstallmentsHelper
  def installment_period_options
    [
      [ t("installments.form.payment_periods.weekly"), "weekly" ],
      [ t("installments.form.payment_periods.bi_weekly"), "bi_weekly" ],
      [ t("installments.form.payment_periods.monthly"), "monthly" ],
      [ t("installments.form.payment_periods.quarterly"), "quarterly" ],
      [ t("installments.form.payment_periods.yearly"), "yearly" ]
    ]
  end
end
