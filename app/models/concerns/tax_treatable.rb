module TaxTreatable
  extend ActiveSupport::Concern

  # Delegates tax treatment to the accountable (Investment or Crypto)
  # Returns nil for account types that don't support tax treatment
  def tax_treatment
    return nil unless accountable.respond_to?(:tax_treatment)
    accountable.tax_treatment&.to_sym
  end

  # Returns the i18n label for the tax treatment
  def tax_treatment_label
    return nil unless tax_treatment
    I18n.t("accounts.tax_treatments.#{tax_treatment}")
  end

  # Returns true if the account has tax advantages (deferred, exempt, or advantaged)
  def tax_advantaged?
    tax_treatment.in?(%i[tax_deferred tax_exempt tax_advantaged])
  end

  # Returns true if gains in this account are taxable
  def taxable?
    tax_treatment == :taxable || tax_treatment.nil?
  end
end
