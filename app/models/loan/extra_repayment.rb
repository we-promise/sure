class Loan
  # The extra amount, and how often it is paid, that a borrower asks the Extra
  # repayments tab to model, as submitted by its form.
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

    # What the form's select offers. Blank is monthly, the default.
    FREQUENCIES = PayoffProjection::EXTRA_FREQUENCIES

    attr_reader :input, :currency, :frequency

    validate :amount_is_a_plain_non_negative_decimal
    validates :frequency, inclusion: { in: FREQUENCIES, message: ->(*) { I18n.t("loans.tabs.extra_repayments.invalid_frequency") } }

    def initialize(amount:, currency:, frequency: nil)
      @input = amount.to_s.strip
      @currency = currency
      @frequency = frequency.presence || "monthly"
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

    # The params the form submitted, for a link that reloads the page and
    # must keep the extra: the account page rebuilds it only from these.
    def to_params
      { amount: input, frequency: frequency }
    end

    # What the amount field shows: the typed amount when it is a plain decimal,
    # sign allowed, so a refused "-1" comes back as typed. nil otherwise: "abc"
    # cannot sit in a number field, and "1e3" or "Infinity" would come back as
    # a figure nobody typed.
    def field_value
      BigDecimal(input) if input.match?(/\A-?\d+(\.\d+)?\z/)
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
