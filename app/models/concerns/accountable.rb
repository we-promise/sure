module Accountable
  extend ActiveSupport::Concern

  TYPES = %w[Depository Investment Crypto Property Vehicle OtherAsset CreditCard Loan OtherLiability]

  # Define empty hash to ensure all accountables have this defined
  SUBTYPES = {}.freeze

  def self.from_type(type)
    return nil unless TYPES.include?(type)
    type.constantize
  end

  included do
    include Enrichable

    has_one :account, as: :accountable, touch: true
  end

  class_methods do
    def classification
      raise NotImplementedError, "Accountable must implement #classification"
    end

    def icon
      raise NotImplementedError, "Accountable must implement #icon"
    end

    def color
      raise NotImplementedError, "Accountable must implement #color"
    end

    # Given a subtype, look up the label for this accountable type
    # Uses i18n with fallback to hardcoded SUBTYPES values
    def subtype_label_for(subtype, format: :short)
      return nil if subtype.nil?

      label_type = format == :long ? :long : :short
      fallback = self::SUBTYPES.dig(subtype, label_type)

      I18n.t(
        "#{name.underscore.pluralize}.subtypes.#{subtype}.#{label_type}",
        default: fallback
      )
    end

    # Convenience method for getting the short label
    def short_subtype_label_for(subtype)
      subtype_label_for(subtype, format: :short)
    end

    # Convenience method for getting the long label
    def long_subtype_label_for(subtype)
      subtype_label_for(subtype, format: :long)
    end

    def favorable_direction
      classification == "asset" ? "up" : "down"
    end

    def display_name
      self.name.pluralize.titleize
    end

    # Sums the balances of all active accounts of this type, converting foreign currencies to the family's currency.
    # @return [BigDecimal] total balance in the family's currency
    def balance_money(family)
      accounts = family.accounts.active.where(accountable_type: self.name).to_a

      foreign_currencies = accounts.filter_map { |a| a.currency if a.currency != family.currency }
      rates = ExchangeRate.rates_for(foreign_currencies, to: family.currency, date: Date.current)

      accounts.sum(BigDecimal(0)) { |account|
        if account.currency == family.currency
          account.balance
        else
          account.balance * (rates[account.currency] || 1)
        end
      }
    end
  end

  def display_name
    self.class.display_name
  end

  def balance_display_name
    "account value"
  end

  def opening_balance_display_name
    "opening balance"
  end

  def icon
    self.class.icon
  end

  def color
    self.class.color
  end

  def classification
    self.class.classification
  end
end
