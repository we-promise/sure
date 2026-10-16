class Loan
  # The extra amount a borrower asks the Extra repayments tab to model, as
  # typed into its form.
  #
  # The form submits over GET, so its `min: 0` is a hint the server cannot rely
  # on. Blank and zero mean "no extra". Anything that is not a plain,
  # non-negative decimal is refused rather than coerced: a negative extra would
  # shrink every repayment and manufacture a balloon, and quietly reading "abc"
  # as zero would show the borrower a figure for something they did not ask.
  class ExtraRepayment
    include ActiveModel::Validations

    # What a number field submits: digits, with an optional fractional part.
    # No sign, exponent or spelled-out infinity.
    AMOUNT_FORMAT = /\A\d+(\.\d+)?\z/

    attr_reader :input, :currency

    validate :amount_is_a_plain_non_negative_decimal

    def initialize(amount:, currency:)
      @input = amount.to_s.strip
      @currency = currency
    end

    # The extra per period in the loan's currency, or nil when there is none
    # to apply: blank, zero once taken to the currency's precision, or refused.
    def amount
      return nil if input.blank? || !valid?

      rounded = BigDecimal(input).round(currency_precision)
      rounded.positive? ? rounded : nil
    end

    def applied?
      amount.present?
    end

    private
      def amount_is_a_plain_non_negative_decimal
        return if input.blank? || input.match?(AMOUNT_FORMAT)

        errors.add(:amount, I18n.t("loans.tabs.extra_repayments.invalid_amount"))
      end

      def currency_precision
        Money::Currency.new(currency).default_precision || 2
      end
  end
end
