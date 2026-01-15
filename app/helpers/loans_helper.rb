module LoansHelper
  def installment_period_options
    [
      [ t("loans.form.installment.payment_periods.weekly"), "weekly" ],
      [ t("loans.form.installment.payment_periods.bi_weekly"), "bi_weekly" ],
      [ t("loans.form.installment.payment_periods.monthly"), "monthly" ],
      [ t("loans.form.installment.payment_periods.quarterly"), "quarterly" ],
      [ t("loans.form.installment.payment_periods.yearly"), "yearly" ]
    ]
  end
end
