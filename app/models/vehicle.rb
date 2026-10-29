class Vehicle < ApplicationRecord
  include Accountable

  attribute :mileage_unit, :string, default: "mi"

  # The purchase price and date live on the account's opening anchor, which is
  # what `purchase_price` and `trend` read. These carry them in from the form:
  # `initial_balance` is picked up by `Account.create_and_sync` on create, and
  # both are written to the anchor here on update. Blank leaves it untouched.
  attribute :initial_balance, :decimal
  attribute :purchase_date, :date

  validate :purchase_date_precedes_entries, if: :persisted?
  after_update :update_purchase_anchor, if: -> { saved_change_to_initial_balance? || saved_change_to_purchase_date? }

  def mileage
    Measurement.new(mileage_value, mileage_unit) if mileage_value.present?
  end

  def purchase_price
    first_valuation_amount
  end

  def trend
    Trend.new(current: account.balance_money, previous: first_valuation_amount)
  end

  class << self
    def color
      "#F23E94"
    end

    def icon
      "car-front"
    end

    def classification
      "asset"
    end
  end

  private
    def purchase_date_precedes_entries
      return if purchase_date.blank?

      if Account::OpeningBalanceManager.new(account).date_error(purchase_date)
        errors.add(:purchase_date, :must_precede_entries)
      end
    end

    def update_purchase_anchor
      return if initial_balance.nil? && purchase_date.nil?

      result = account.set_opening_anchor_balance(
        balance: initial_balance || account.opening_anchor_balance,
        date: purchase_date
      )
      return if result.success?

      errors.add(:base, result.error)
      raise ActiveRecord::RecordInvalid.new(self)
    end

    # Form inputs for the opening anchor, not vehicle details a provider could
    # overwrite.
    def ignored_enrichable_attributes
      super + %w[initial_balance purchase_date]
    end

    def first_valuation_amount
      account.entries.valuations.order(:date).first&.amount_money || account.balance_money
    end
end
