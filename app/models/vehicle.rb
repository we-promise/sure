class Vehicle < ApplicationRecord
  include Accountable

  attribute :mileage_unit, :string, default: "mi"

  # Form inputs for the purchase price and date, stored on the opening anchor.
  attribute :initial_balance, :decimal
  attribute :purchase_date, :date

  validate :purchase_date_is_valid, if: :persisted?
  after_update :update_purchase_anchor, if: -> { purchase_price_edited? || purchase_date_edited? }

  # An unparseable purchase date casts to nil, which reads as unchanged, and
  # the account would then skip validating this record.
  def changed_for_autosave?
    super || invalid_purchase_date?
  end

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
    # The form posts both fields prefilled on every edit, so only a value that
    # differs from what is stored counts as an edit.
    def purchase_price_edited?
      initial_balance.present? && initial_balance != purchase_price.amount
    end

    def purchase_date_edited?
      purchase_date.present? && purchase_date != account.opening_anchor_date
    end

    def invalid_purchase_date?
      purchase_date.nil? && purchase_date_before_type_cast.present?
    end

    def purchase_date_is_valid
      if invalid_purchase_date?
        errors.add(:purchase_date, :invalid)
      elsif purchase_date_edited? && Account::OpeningBalanceManager.new(account).date_error(purchase_date)
        errors.add(:purchase_date, :must_precede_entries)
      end
    end

    def update_purchase_anchor
      price_edited = purchase_price_edited?
      current_balance = account.balance

      result = account.set_opening_anchor_balance(
        balance: price_edited ? initial_balance : unedited_anchor_balance,
        date: (purchase_date if purchase_date_edited?)
      )
      raise_purchase_error(result.error) unless result.success?

      keep_current_balance(current_balance) if price_edited
    end

    # A valuation can predate the anchor, and then it is the purchase price
    # shown; moving only the date keeps the anchor's own balance.
    def unedited_anchor_balance
      account.has_opening_anchor? ? account.opening_anchor_balance : purchase_price.amount
    end

    # With no valuation between the anchor and today, the anchor carries
    # forward to today, so the new purchase price would become the current
    # value too. Pin today's value, as Account.create_and_sync does on create.
    def keep_current_balance(balance)
      anchor_date = account.opening_anchor_date
      return unless anchor_date < Date.current
      return if account.entries.valuations.where(date: (anchor_date + 1)..Date.current).exists?

      result = Account::ReconciliationManager.new(account).reconcile_balance(balance: balance, date: Date.current)
      raise_purchase_error(result.error_message) unless result.success?
    end

    def raise_purchase_error(message)
      errors.add(:base, message)
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
