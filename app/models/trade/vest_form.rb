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
# opening any of them opens this form. Saving updates them in place, so what
# the user added to one (notes, tags, attachments) stays.
class Trade::VestForm
  include ActiveModel::Model

  INCOME_LABEL = "Contribution".freeze
  TAX_LABEL = "Withdrawal".freeze
  # Blank tax lines the form offers beyond those a vest already has.
  BLANK_TAX_LINES = 5

  # id is the tax entry the line was read from, so a saved line updates that
  # entry whatever lines around it were cleared. amount_invalid is a typed
  # amount that isn't a number, kept apart so the line still counts as filled.
  TaxLine = Data.define(:id, :name, :category_id, :amount, :amount_invalid) do
    def initialize(id: nil, name: "", category_id: nil, amount: nil, amount_invalid: false) = super
  end

  attr_accessor :account, :date, :ticker, :manual_ticker, :vested_qty, :units_withheld, :price,
                :income_category_id
  attr_reader :entry, :tax_lines

  validates :date, presence: true
  validates :vested_qty, numericality: { greater_than: 0 }
  validates :price, numericality: { greater_than: 0 }
  validates :units_withheld, numericality: { greater_than_or_equal_to: 0 }, allow_blank: true
  validate :account_holds_investments
  validate :security_present, unless: :entry
  validate :tax_lines_have_amounts
  validate :tax_lines_name_each_entry_once
  validate :withheld_within_vested

  # The form for a vest already recorded, filled in from its entries.
  def self.for(entry)
    trade = entry.trade
    income, taxes = parts_of(entry)

    new(
      entry: entry,
      account: entry.account,
      date: entry.date,
      vested_qty: trade.qty + trade.units_withheld.to_d,
      units_withheld: trade.units_withheld,
      price: trade.price,
      income_category_id: income&.entryable&.category_id,
      tax_lines: taxes.map { |tax| { id: tax.id, name: tax.name, category_id: tax.entryable.category_id, amount: tax.amount } }
    )
  end

  # The vest's income entry and its tax entries, oldest first, told apart by
  # their labels.
  def self.parts_of(entry)
    parts = entry.vest_parts.includes(:entryable).order(:created_at).select(&:transaction?)
    labelled = ->(label) { parts.select { |part| part.entryable.investment_activity_label == label } }
    [ labelled.(INCOME_LABEL).first, labelled.(TAX_LABEL) ]
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
      amount = BigDecimal(line[:amount].to_s.strip, exception: false) if line[:amount].present?
      amount = nil unless amount&.finite?
      TaxLine.new(id: line[:id].presence, name: line[:name].to_s.strip, category_id: line[:category_id].presence,
                  amount: amount, amount_invalid: line[:amount].present? && amount.nil?)
    end
  end

  def persisted?
    entry.present?
  end

  def currency
    account.currency
  end

  # The shares that reached the account: those vested less those withheld.
  def received_qty
    vested_qty.to_d - units_withheld.to_d
  end

  def shares_value
    received_qty * price.to_d
  end

  def gross_pay
    vested_qty.to_d * price.to_d
  end

  # The tax lines saved: those with an amount, or, when none has one, the
  # withheld shares' value as one line.
  def taxes
    entered = tax_lines.select(&:amount)
    return entered if entered.any?

    withheld_value = units_withheld.to_d * price.to_d
    withheld_value.positive? ? [ TaxLine.new(amount: withheld_value) ] : []
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
    tax_lines.reject { |line| blank_line?(line) } + Array.new(BLANK_TAX_LINES) { TaxLine.new }
  end

  def save
    return false unless valid?

    Entry.transaction do
      # A tax-only save doesn't update the vest row, so lock it: a second save
      # of the same vest waits here and then reads the first save's taxes.
      entry&.lock!
      vest = entry || account.entries.new(entryable: Trade.new(security: security))
      vest.assign_attributes(name: Trade.build_name("vest", received_qty, vest.trade.security.ticker), date: date, amount: shares_value, currency: currency)
      vest.trade.assign_attributes(
        qty: received_qty, price: price.to_d, fee: 0, currency: currency,
        units_withheld: units_withheld.presence&.to_d, investment_activity_label: Trade::VEST_LABEL
      )
      vest.vest_write = true
      vest.save!

      income, old_taxes = entry ? self.class.parts_of(vest) : [ nil, [] ]
      parts = [ write_part(vest, income, name: I18n.t("vests.entries.income", ticker: vest.trade.security.ticker),
                           category_id: income_category_id, amount: -gross_pay, label: INCOME_LABEL) ]
      parts += taxes.map do |tax|
        write_part(vest, old_taxes.find { |old| old.id == tax.id }, name: tax.name.presence || I18n.t("vests.entries.taxes_withheld"),
                   category_id: tax.category_id, amount: tax.amount, label: TAX_LABEL)
      end
      (old_taxes - parts).each do |removed|
        removed.vest_write = true
        removed.destroy_unless_split_part_transferred!
      end

      [ vest, *parts ].each do |saved|
        saved.lock_saved_attributes!
        saved.mark_user_modified!
      end
      @entry = vest
    end

    account.sync_later
    EntryScheduledSyncJob.schedule_for(@entry)
    true
  rescue ActiveRecord::RecordInvalid => e
    errors.add(:base, e.record.errors.full_messages.to_sentence)
    false
  rescue Entry::SplitPartTransferredError
    errors.add(:base, I18n.t("vests.form.tax_transferred"))
    false
  end

  private
    # Updates an income or tax entry in place, or adds it when there is none.
    def write_part(vest, part, name:, category_id:, amount:, label:)
      part ||= vest.vest_parts.build(entryable: Transaction.new)
      part.vest_write = true
      part.assign_attributes(account: account, date: date, name: name, amount: amount, currency: currency)
      part.entryable.assign_attributes(category: family_category(category_id), investment_activity_label: label)
      part.save!
      part
    end

    # Only the family's own categories; an id from anywhere else is no category.
    def family_category(id)
      account.family.categories.find_by(id: id) if id.present?
    end

    def security
      return @security if defined?(@security)

      @security = Security::Resolver.from_form(ticker: ticker, manual_ticker: manual_ticker)
    end

    def blank_line?(line)
      line.name.blank? && line.category_id.blank? && line.amount.nil? && !line.amount_invalid
    end

    def account_holds_investments
      errors.add(:base, I18n.t("vests.form.investment_account_required")) unless account&.investment?
    end

    def security_present
      errors.add(:base, I18n.t("vests.form.security_required")) unless security
    end

    # Some shares must reach the account, or there is no lot to record.
    def withheld_within_vested
      errors.add(:base, I18n.t("vests.form.withheld_exceeds_vested")) unless received_qty.positive?
    end

    # Two lines naming one entry would save only the last, while the totals
    # counted both.
    def tax_lines_name_each_entry_once
      ids = tax_lines.filter_map(&:id)
      errors.add(:base, I18n.t("vests.form.tax_line_repeated")) if ids.uniq.size < ids.size
    end

    # A tax line needs an amount once anything else is filled in, a number
    # (BigDecimal, so "300oops" isn't read as 300), and money out, never in.
    def tax_lines_have_amounts
      amounts = tax_lines.reject { |line| blank_line?(line) }.map(&:amount)
      errors.add(:base, I18n.t("vests.form.tax_amount_required")) if amounts.any?(&:nil?)
      errors.add(:base, I18n.t("vests.form.tax_amount_negative")) if amounts.compact.any?(&:negative?)
    end
end
