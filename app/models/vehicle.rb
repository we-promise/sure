class Vehicle < ApplicationRecord
  include Accountable

  attribute :mileage_unit, :string, default: "mi"

  # Form inputs for the purchase price and date, stored on the opening anchor.
  attribute :initial_balance, :decimal
  attribute :purchase_date, :date
  # The price the form showed. The account's balance is saved first and can
  # rewrite a same-day opening anchor, so edits are judged against this.
  attribute :initial_balance_shown, :decimal

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

  # The opening anchor ("Original purchase price") is what the form edits, so
  # it is the purchase price even when a valuation predates it.
  def purchase_price
    return Money.new(account.opening_anchor_balance, account.currency) if account.has_opening_anchor?

    first_valuation_amount
  end

  def trend
    Trend.new(current: account.balance_money, previous: purchase_price)
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
    # differs from what was shown (or, without that, stored) counts as an edit.
    # Both sides are rounded as the money field displays them.
    def purchase_price_edited?
      return false if initial_balance.blank?

      round_to_currency(initial_balance) != round_to_currency(initial_balance_shown || purchase_price.amount)
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
      current_balance = account.balance
      anchor_balance = purchase_price_edited? ? initial_balance : unedited_anchor_balance

      result = account.set_opening_anchor_balance(
        balance: anchor_balance,
        date: (purchase_date if purchase_date_edited?)
      )
      raise_purchase_error(result.error) unless result.success?

      # Applied; a later save of this record, such as lock_saved_attributes!,
      # must not apply them again against the anchor they just moved.
      self.initial_balance = self.purchase_date = self.initial_balance_shown = nil

      keep_current_balance(current_balance) if anchor_balance != current_balance
    end

    # Moving only the date keeps the purchase price. A same-day anchor is also
    # today's balance, which the account update may just have rewritten; the
    # price shown is what it held before.
    def unedited_anchor_balance
      return initial_balance_shown if initial_balance_shown && account.opening_anchor_date == Date.current

      purchase_price.amount
    end

    def round_to_currency(amount)
      amount.round(Money::Currency.new(account.currency).default_precision)
    end

    # With no valuation between the anchor and today, the anchor carries
    # forward to today, so a new anchor balance would become the current value
    # too. Pin today's value, as Account.create_and_sync does on create.
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
      super + %w[initial_balance initial_balance_shown purchase_date]
    end

    def first_valuation_amount
      account.entries.valuations.order(:date).first&.amount_money || account.balance_money
    end
end
