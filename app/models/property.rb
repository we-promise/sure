class Property < ApplicationRecord
  include Accountable

  SUBTYPES = {
    "single_family_home" => { short: "Single Family Home", long: "Single Family Home" },
    "multi_family_home" => { short: "Multi-Family Home", long: "Multi-Family Home" },
    "condominium" => { short: "Condo", long: "Condominium" },
    "townhouse" => { short: "Townhouse", long: "Townhouse" },
    "investment_property" => { short: "Investment Property", long: "Investment Property" },
    "second_home" => { short: "Second Home", long: "Second Home" },
    "apartment" => { short: "Apartment", long: "Apartment" },
    "plot" => { short: "Plot", long: "Plot / Land" },
    "commercial" => { short: "Commercial", long: "Commercial Property" },
    "agri_land" => { short: "Agri Land", long: "Agricultural Land" }
  }.freeze

  has_one :address, as: :addressable, dependent: :destroy
  # Transactions with this tag count as the property's purchase costs. The
  # tag must be the family's own (checked on Account, which knows the family).
  belongs_to :cost_tag, class_name: "Tag", optional: true

  accepts_nested_attributes_for :address

  attribute :area_unit, :string, default: "sqft"

  class << self
    def icon
      "home"
    end

    def color
      "#06AED4"
    end

    def classification
      "asset"
    end
  end

  SQFT_PER_SQM = 10.7639

  def area
    Measurement.new(area_value, area_unit) if area_value.present?
  end

  # Living area in whole square feet, the unit US valuation providers take;
  # nil when no usable (positive) area is stored.
  def area_in_sqft
    return nil unless area_value.to_i.positive?

    area_unit.to_s.strip.downcase == "sqm" ? (area_value * SQFT_PER_SQM).round : area_value
  end

  # Whether the user has set the living area, rather than it being the figure
  # an AVM provider returned when the property was created.
  def user_set_area?
    locked?(:area_value) || locked?(:area_unit)
  end

  def purchase_price
    first_valuation_amount
  end

  def trend
    Trend.new(current: account.balance_money, previous: first_valuation_amount)
  end

  # Whether the overview should also show the trend in the family currency:
  # the property is valued in another currency and has a purchase value.
  def family_currency_trend_applicable?
    account.currency != account.family.currency && first_valuation_entry.present?
  end

  # The trend measured in the family currency, so a currency move that hides
  # or invents a gain shows up. The purchase value is converted at the rate on
  # its own date and the current value at today's rate.
  #
  # Only stored exchange rates are used (no provider call while rendering),
  # picked as ExchangeRate.find_stored_rate does: the latest on or before the
  # date, else the earliest after it. Never 1:1; nil when no rate is stored.
  def family_currency_trend
    return nil unless family_currency_trend_applicable?

    purchase = first_valuation_entry
    family_currency = account.family.currency
    previous = convert_with_stored_rate(purchase.amount_money, family_currency, purchase.date)
    current = convert_with_stored_rate(account.balance_money, family_currency, Date.current)
    return nil if previous.nil? || current.nil?

    Trend.new(current: current, previous: previous)
  end

  def reload(*)
    remove_instance_variable(:@first_valuation_entry) if defined?(@first_valuation_entry)
    @purchase_costs = nil
    @stored_rates = nil
    super
  end

  # The transactions carrying the cost tag, in any of the family's accounts
  # that +user+ can see, closed ones included (the costs stay part of the
  # purchase). Excluded, pending and split-parent entries and transfers
  # (Transaction::TRANSFER_KINDS, loan payments among them) are left out, as
  # in spending totals.
  def cost_entries_for(user)
    return Entry.none if cost_tag_id.nil?

    tagged = Tagging.where(tag_id: cost_tag_id, taggable_type: "Transaction").select(:taggable_id)

    account.family.entries
           .where(account_id: user.accessible_accounts.historical.select(:id))
           .where(entryable_type: "Transaction", entryable_id: Transaction.where(id: tagged).where.not(kind: Transaction::TRANSFER_KINDS).select(:id))
           .where(excluded: false)
           .excluding_pending
           .excluding_split_parents
  end

  # The sum of the linked costs in +currency+: outflows add and refunds
  # subtract. Each transaction is converted at the stored rate on its own
  # date; nil when a rate is missing. The overview reads it for several
  # figures, so it is computed once per viewer and currency.
  def purchase_costs_for(user, currency: account.currency)
    @purchase_costs ||= {}
    key = [ user.id, currency ]
    return @purchase_costs[key] if @purchase_costs.key?(key)

    totals = cost_entries_for(user).group("entries.currency", "entries.date").sum("entries.amount")
    converted = totals.map { |(from_currency, date), amount| convert_with_stored_rate(Money.new(amount, from_currency), currency, date) }

    @purchase_costs[key] = converted.any?(&:nil?) ? nil : converted.sum(Money.new(0, currency))
  end

  # The purchase price plus the linked costs, in +currency+; nil when a rate
  # is missing.
  def cost_basis_for(user, currency: account.currency)
    purchase = first_valuation_entry
    purchase_value = convert_with_stored_rate(first_valuation_amount, currency, purchase&.date || Date.current)
    costs = purchase_costs_for(user, currency: currency)
    return nil if purchase_value.nil? || costs.nil?

    purchase_value + costs
  end

  # The current value against the cost basis, in the property's currency.
  def cost_adjusted_trend_for(user)
    basis = cost_basis_for(user)
    Trend.new(current: account.balance_money, previous: basis) if basis
  end

  # The same in the family currency, for a property valued in another one.
  def family_currency_cost_adjusted_trend_for(user)
    return nil unless family_currency_trend_applicable?

    family_currency = account.family.currency
    basis = cost_basis_for(user, currency: family_currency)
    current = convert_with_stored_rate(account.balance_money, family_currency, Date.current)
    Trend.new(current: current, previous: basis) if basis && current
  end

  def balance_display_name
    "market value"
  end

  def opening_balance_display_name
    "original purchase price"
  end

  # Balance updates are recorded as "Manual value update" reconciliations;
  # rename the one an AVM provider just wrote so the activity feed shows
  # where the value came from. Account::ReconciliationManager resets the name
  # on any later write to that day's entry.
  def name_avm_valuation!(date = Date.current)
    return if avm_provider.blank?

    entry = account.entries.valuations.find_by(date: date)
    return unless entry&.entryable&.reconciliation?

    provider_name = I18n.t("properties.avm_providers.#{avm_provider}", default: avm_provider.titleize)
    entry.update!(name: I18n.t("providers.property_valuation.entry_name", provider: provider_name))
  end

  # Whether an unlinked property can be linked to the given AVM provider for
  # automatic refreshes. Only address-based providers qualify: ID-based
  # providers (Chimnie) need an identifier that only the create-time lookup
  # supplies. The account must already be in the provider's currency so a
  # refresh can't write a valuation in the wrong currency. Unlike the
  # create-time lookup, which always sets the country, a manual address may
  # omit it, so require one to confirm the property is in the provider's
  # country.
  def avm_linkable?(provider_key)
    return false if avm_provider.present? || address&.country.blank?

    provider_class = Provider::PropertyValuationConcept.provider_class(provider_key)
    return false if provider_class.nil? || provider_class.requires_external_id?

    account.currency == provider_class.valuation_currency && provider_class.lookup_ready?(address)
  end

  # Configured providers this property can be linked to.
  def linkable_avm_providers
    return [] if avm_provider.present?

    registry = Provider::Registry.for_concept(:property_valuations)
    registry.provider_keys.select { |key| avm_linkable?(key) && registry.get_provider(key).present? }
  end

  # Links the property to an AVM provider and runs its first valuation right
  # away. The link is kept only if that valuation succeeds; a failure (an
  # address the provider can't value, an exhausted monthly budget) reverts
  # it, so the property can still be linked to another provider instead of
  # being stuck on one that never worked. Returns whether the link was kept.
  #
  # Claiming and reverting are conditional updates, so overlapping link
  # attempts can't clear each other's link: only the attempt that claimed the
  # unlinked property runs the valuation, and the revert only applies while
  # that attempt's link is still unsynced.
  def link_avm_provider!(provider_key)
    raise ArgumentError, "#{provider_key} can't be linked to this property" unless avm_linkable?(provider_key)

    key = provider_key.to_s
    claimed = Property.where(id: id, avm_provider: nil)
                      .update_all(avm_provider: key, avm_last_synced_on: nil, updated_at: Time.current)
    return false unless claimed == 1

    SyncPropertyValuationsJob.perform_now(property_id: id, force: true)
    reload
    return true if avm_provider == key && avm_last_synced_on.present?

    Property.where(id: id, avm_provider: key, avm_last_synced_on: nil)
            .update_all(avm_provider: nil, updated_at: Time.current)
    reload
    false
  end

  private
    # Read up to three times per overview render (the card check, the trend
    # and its purchase value), so it is looked up once.
    def first_valuation_entry
      return @first_valuation_entry if defined?(@first_valuation_entry)

      @first_valuation_entry = account.entries.valuations.order(:date).first
    end

    def first_valuation_amount
      first_valuation_entry&.amount_money || account.balance_money
    end

    def convert_with_stored_rate(money, to_currency, date)
      return money if money.currency.iso_code == to_currency

      rate = stored_rate(money.currency.iso_code, to_currency, date)
      return nil unless rate

      money.exchange_to(to_currency, custom_rate: rate.rate)
    end

    def stored_rate(from, to, date)
      @stored_rates ||= {}
      key = [ from, to, date ]
      return @stored_rates[key] if @stored_rates.key?(key)

      @stored_rates[key] = ExchangeRate.find_stored_rate(from: from, to: to, date: date)
    end
end
