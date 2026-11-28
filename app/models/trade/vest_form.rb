# Records an RSU vest, entered on one form, as the entries it is made of:
#
# - the shares received, at the price they vested at, paid for from cash as a
#   buy would be, so the lot costs that price;
# - the gross pay they were, (received + withheld) x price, as income;
# - the taxes withheld from that pay, one entry per paystub line, each in its
#   own category.
#
# Cash nets to the pay left after the shares and the taxes: nothing, when the
# taxes are exactly the withheld shares. The cash flow reads the income and
# taxes as it reads a paycheck, and the investment returns read them as money
# in and out from outside (Contribution, Withdrawal), with the shares internal.
#
# The income and tax entries point at the vest's entry (Entry#vest_entry), so
# opening any of them opens this form, and saving replaces them together.
class Trade::VestForm
  include ActiveModel::Model

  INCOME_LABEL = "Contribution".freeze
  TAX_LABEL = "Withdrawal".freeze
  # Blank tax lines the form offers beyond those a vest already has.
  BLANK_TAX_LINES = 5

  TaxLine = Data.define(:name, :category_id, :amount)

  attr_accessor :account, :date, :ticker, :manual_ticker, :qty, :units_withheld, :price,
                :income_category_id
  attr_reader :entry, :tax_lines

  validates :date, presence: true
  validates :qty, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than: 0 }
  validates :units_withheld, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validate :account_holds_investments
  validate :security_present, unless: :entry

  # The form for a vest already recorded, filled in from its entries.
  def self.for(entry)
    trade = entry.trade
    parts = entry.vest_parts.includes(:entryable).order(:created_at).to_a
    income = parts.find { |part| part.transaction? && part.amount.negative? }

    new(
      entry: entry,
      account: entry.account,
      date: entry.date,
      qty: trade.qty,
      units_withheld: trade.units_withheld,
      price: trade.price,
      income_category_id: income&.entryable&.category_id,
      tax_lines: (parts - [ income ]).select(&:transaction?).map do |tax|
        { name: tax.name.delete_prefix(name_prefix(trade.security.ticker)), category_id: tax.entryable.category_id, amount: tax.amount }
      end
    )
  end

  def self.name_prefix(ticker)
    "#{ticker} vest: "
  end

  def initialize(entry: nil, tax_lines: [], **attrs)
    @entry = entry
    self.tax_lines = tax_lines
    super(**attrs)
  end

  def tax_lines=(lines)
    lines = lines.values if lines.respond_to?(:values) && !lines.is_a?(Array)
    @tax_lines = Array(lines).map do |line|
      line = line.to_h.symbolize_keys
      TaxLine.new(name: line[:name].to_s.strip, category_id: line[:category_id].presence, amount: line[:amount].presence&.to_d)
    end
  end

  def persisted?
    entry.present?
  end

  def currency
    account.currency
  end

  def shares_value
    qty.to_d * price.to_d
  end

  def gross_pay
    (qty.to_d + units_withheld.to_d) * price.to_d
  end

  # The tax lines saved: those with an amount, or, when none has one, the
  # withheld shares' value as one line.
  def taxes
    entered = tax_lines.select(&:amount)
    return entered if entered.any?

    withheld_value = units_withheld.to_d * price.to_d
    withheld_value.positive? ? [ TaxLine.new(name: "", category_id: nil, amount: withheld_value) ] : []
  end

  def taxes_total
    taxes.sum(BigDecimal("0"), &:amount)
  end

  # Pay left in the account as cash once the shares and taxes are taken out.
  def cash_left
    gross_pay - taxes_total - shares_value
  end

  # The tax lines to show: those entered, then blanks to fill in.
  def tax_lines_for_form
    tax_lines.select(&:amount) + Array.new(BLANK_TAX_LINES) { TaxLine.new(name: "", category_id: nil, amount: nil) }
  end

  def save
    return false unless valid?

    Entry.transaction do
      vest = entry || account.entries.new(entryable: Trade.new(security: security))
      ticker = vest.trade.security.ticker
      vest.assign_attributes(name: Trade.build_name("vest", qty, ticker), date: date, amount: shares_value, currency: currency)
      vest.trade.assign_attributes(
        qty: qty.to_d, price: price.to_d, fee: 0, currency: currency,
        units_withheld: units_withheld.presence&.to_d, investment_activity_label: Trade::VEST_LABEL
      )
      vest.save!

      vest.vest_parts.destroy_all
      parts = [ build_part(vest, name: "income", category_id: income_category_id, amount: -gross_pay, label: INCOME_LABEL) ]
      parts += taxes.map do |tax|
        build_part(vest, name: tax.name.presence || "taxes withheld", category_id: tax.category_id, amount: tax.amount, label: TAX_LABEL)
      end
      parts.each(&:save!)

      [ vest, *parts ].each do |saved|
        saved.lock_saved_attributes!
        saved.mark_user_modified!
      end
      @entry = vest
    end

    account.sync_later
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence)
    false
  end

  private
    def build_part(vest, name:, category_id:, amount:, label:)
      vest.vest_parts.build(
        account: account,
        date: date,
        name: "#{self.class.name_prefix(vest.trade.security.ticker)}#{name}",
        amount: amount,
        currency: currency,
        entryable: Transaction.new(category: family_category(category_id), investment_activity_label: label)
      )
    end

    # Only the family's own categories; an id from anywhere else is no category.
    def family_category(id)
      account.family.categories.find_by(id: id) if id.present?
    end

    # Users can look up a ticker from a provider or enter an offline one, as on
    # the trade form.
    def security
      return @security if defined?(@security)

      parsed = ticker.present? ? Security.parse_combobox_id(ticker) : { ticker: manual_ticker }
      @security = if parsed[:ticker].present?
        Security::Resolver.new(
          parsed[:ticker],
          exchange_operating_mic: parsed[:exchange_operating_mic],
          price_provider: parsed[:price_provider]
        ).resolve
      end
    end

    def account_holds_investments
      errors.add(:base, I18n.t("vests.form.investment_account_required")) unless account&.investment?
    end

    def security_present
      errors.add(:base, I18n.t("vests.form.security_required")) unless security
    end
end
