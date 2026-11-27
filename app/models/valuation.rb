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

    # A reconciliation on a linked account was left by a sync, not typed in,
    # so it isn't called "manual" there.
    return synced_name(name.synced_translation_key, entry.account) if reconciliation? && entry.account.linked?

    translation_key = "valuations.names.#{name.translation_key}"
    if opening_anchor? &&
        !I18n.exists?(translation_key, I18n.locale, fallback: false) &&
        I18n.exists?("valuations.show.opening_balance", I18n.locale, fallback: false)
      return I18n.t("valuations.show.opening_balance")
    end

    I18n.t(translation_key)
  end

  private
    # Names the provider ("Value synced from SnapTrade") where this locale has
    # that wording, else the plain synced name rather than an English fallback.
    def synced_name(key, account)
      with_provider = "valuations.names.#{key}_from"
      provider = account.provider_display_name
      if provider && I18n.exists?(with_provider, I18n.locale, fallback: false)
        I18n.t(with_provider, provider: provider)
      else
        I18n.t("valuations.names.#{key}")
      end
    end
end
