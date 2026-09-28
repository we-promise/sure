module LoansHelper
  # The rate types the form offers, plus the loan's own when a provider wrote
  # one the form does not know (#100 decision 8). Without it the select has no
  # matching option, the browser submits the first one, and saving any other
  # field silently turns an "arm" loan into a fixed one.
  def loan_rate_type_options(loan)
    options = [
      [ t("loans.form.rate_type_fixed"), Loan::FIXED_RATE_TYPE ],
      [ t("loans.form.rate_type_variable"), "variable" ],
      [ t("loans.form.rate_type_adjustable"), "adjustable" ]
    ]
    return options if loan.rate_type.blank? || options.any? { |_, value| value == loan.rate_type }

    options << [ loan.rate_type.titleize, loan.rate_type ]
  end
end
