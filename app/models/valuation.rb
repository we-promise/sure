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

    I18n.t("valuations.names.#{name.translation_key}")
  end
end
