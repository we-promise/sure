class Valuation < ApplicationRecord
  include Entryable

  enum :kind, {
    reconciliation: "reconciliation",
    opening_anchor: "opening_anchor",
    current_anchor: "current_anchor"
  }, validate: true, default: "reconciliation"

  class << self
    # Returns the stable, persisted name for a reconciliation valuation.
    def build_reconciliation_name(accountable_type)
      Valuation::Name.new("reconciliation", accountable_type).to_s
    end

    # Returns the stable, persisted name for an opening balance valuation.
    def build_opening_anchor_name(accountable_type)
      Valuation::Name.new("opening_anchor", accountable_type).to_s
    end

    # Returns the stable, persisted name for a provider-managed current valuation.
    def build_current_anchor_name(accountable_type)
      Valuation::Name.new("current_anchor", accountable_type).to_s
    end
  end

  # Localizes generated names for display while preserving custom entry names.
  def display_name(entry)
    name = Valuation::Name.new(kind, entry.account.accountable_type)
    return entry.name unless entry.name == name.to_s

    translation_key = "valuations.names.#{name.translation_key}"
    if opening_anchor? &&
        !I18n.exists?(translation_key, I18n.locale, fallback: false) &&
        I18n.exists?("valuations.show.opening_balance", I18n.locale, fallback: false)
      return I18n.t("valuations.show.opening_balance")
    end

    I18n.t(translation_key)
  end
end
