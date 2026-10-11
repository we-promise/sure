# How quickly the money in an account can be reached ("availability").
#
# Four levels, stored on `accounts.liquidity`:
#
# - immediate:  current account, cash, instant-access savings
# - short_term: freely tradable brokerage, crypto, money market, notice savings
# - locked:     locked until `available_on` (term deposit, building savings)
# - long_term:  retirement accounts, property, vehicles
#
# The stored level comes from the account's type and subtype
# (Accountable::Rules) until the user picks one on the form; a manual pick is
# kept in `locked_attributes` so subtype changes and syncs never overwrite it.
#
# A locked account becomes available on its release date by calculation only:
# no job flips the column. Every scope and predicate therefore takes the date
# it is asked about, so historical figures evaluate the release date per day
# with today's classification.
#
# This is the one place that answers "is this money available?". Do not
# hardcode `accountable_type: "Depository"` for that question again; see
# docs/llm-guides/account-availability.md.
module Account::Liquidity
  extend ActiveSupport::Concern

  LEVELS = %w[immediate short_term locked long_term].freeze
  AVAILABLE_LEVELS = %w[immediate short_term].freeze
  BOUND_LEVELS = %w[locked long_term].freeze

  # Form value for "follow the subtype again".
  AUTOMATIC = "automatic".freeze

  MAX_RENEWAL_TERM_MONTHS = 600

  included do
    validates :liquidity, inclusion: { in: LEVELS }
    validates :renewal_term_months,
              numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_RENEWAL_TERM_MONTHS },
              allow_nil: true
    validates :renewal_term_months, presence: true, if: -> { auto_renew? && liquidity == "locked" }
    validate :liquidity_choice_must_be_known

    before_validation :apply_liquidity

    # Assets that can be reached at short notice on `date`: immediate and
    # short-term accounts, plus locked accounts whose release date has come.
    # Liabilities are deliberately separate (see .short_term_liabilities): a
    # combined scope would count credit cards as available wealth.
    scope :available_assets_on, ->(date) {
      assets.where(liquidity: AVAILABLE_LEVELS).or(assets.released_on(date))
    }

    # Money for this month's budget (a brokerage account counts as
    # available wealth, but not as budget money).
    scope :immediate_assets_on, ->(date) {
      assets.where(liquidity: "immediate").or(assets.released_on(date))
    }

    # Assets that are not available on `date`.
    scope :bound_assets_on, ->(date) {
      assets.where(liquidity: "long_term").or(
        assets.where(liquidity: "locked")
              .where("accounts.auto_renew OR accounts.available_on IS NULL OR accounts.available_on > ?", date)
      )
    }

    # Debts that eat into available wealth: credit cards and
    # overdraft lines. Loans and mortgages are long-term and stay out.
    scope :short_term_liabilities, -> { liabilities.where(liquidity: AVAILABLE_LEVELS) }

    # Locked accounts whose release date is on or before `date`. An account
    # that renews automatically never releases by itself.
    scope :released_on, ->(date) {
      where(liquidity: "locked", auto_renew: false).where(available_on: ..date)
    }
  end

  class_methods do
    # "Today" for the family, never the server's date: a term deposit that
    # matures on the 1st is available from midnight in the family's time zone.
    def liquidity_today_for(family)
      zone = ActiveSupport::TimeZone[family&.timezone.to_s] || Time.zone
      Time.current.in_time_zone(zone).to_date
    end
  end

  # Virtual attribute for the form: AUTOMATIC or one of LEVELS.
  attr_reader :liquidity_choice

  def liquidity_choice=(value)
    @liquidity_choice = value.to_s.presence
  end

  # The value the form's select shows.
  def liquidity_choice_for_form
    liquidity_choice || (liquidity_manual? ? liquidity : AUTOMATIC)
  end

  def liquidity_manual?
    locked?(:liquidity)
  end

  def default_liquidity
    return "immediate" if accountable_class.nil?

    accountable_class.rules_for(subtype).liquidity
  end

  def subtype_rules
    accountable_class&.rules_for(subtype)
  end

  def available_on?(date = liquidity_today)
    return false if liability?
    return true if liquidity.in?(AVAILABLE_LEVELS)

    liquidity == "locked" && !auto_renew? && available_on.present? && available_on <= date
  end

  # The level that applies on `date`: a locked account past its release date
  # reads as immediate.
  def effective_liquidity(date = liquidity_today)
    return "immediate" if liquidity == "locked" && available_on?(date)

    liquidity
  end

  # The next date the money is released, rolled forward by the renewal term
  # when the deposit renews automatically.
  def next_release_date(date = liquidity_today)
    return nil unless liquidity == "locked" && available_on.present?
    return available_on unless auto_renew? && renewal_term_months.to_i.positive?

    # Whole terms that fit between the original date and `date` by calendar
    # month, plus one when that renewal still falls before `date`. Counted
    # from the original date: stepping from the previous result would let a
    # month-end date slip (Jan 31 -> Feb 28 -> Mar 28).
    months = (date.year * 12 + date.month) - (available_on.year * 12 + available_on.month)
    terms = [ months / renewal_term_months, 0 ].max
    terms += 1 if (available_on >> (terms * renewal_term_months)) < date
    available_on >> (terms * renewal_term_months)
  end

  def days_until_available(date = liquidity_today)
    release = next_release_date(date)
    return nil if release.nil? || release < date

    (release - date).to_i
  end

  def liquidity_label
    I18n.t("accounts.liquidity.levels.#{liquidity}")
  end

  def liquidity_today
    self.class.liquidity_today_for(family)
  end

  # Writes the subtype default straight to the column when the subtype was
  # changed outside the account form (provider syncs update the accountable
  # directly). A manual choice is left alone.
  def refresh_default_liquidity!
    return if liquidity_manual?

    default = default_liquidity
    return if liquidity == default

    attributes = { liquidity: default }
    attributes.merge!(available_on: nil, auto_renew: false, renewal_term_months: nil) unless default == "locked"
    update_columns(attributes)
  end

  private
    def apply_liquidity
      case liquidity_choice
      when nil
        self.liquidity = default_liquidity if !liquidity_manual? && liquidity_default_needed?
      when AUTOMATIC
        self.locked_attributes = (locked_attributes || {}).except("liquidity")
        self.liquidity = default_liquidity
      when *LEVELS
        self.locked_attributes = (locked_attributes || {}).merge("liquidity" => Time.current.iso8601)
        self.liquidity = liquidity_choice
        # Written even when unchanged: a subtype change saved in the same form
        # writes the subtype default from the accountable's callback first.
        liquidity_will_change!
      end

      clear_release_fields unless liquidity == "locked"
    end

    def liquidity_default_needed?
      new_record? || will_save_change_to_accountable_type? ||
        accountable&.will_save_change_to_attribute?(:subtype)
    end

    # The release date and renewal only mean something on a locked account.
    def clear_release_fields
      self.available_on = nil
      self.auto_renew = false
      self.renewal_term_months = nil
    end

    def liquidity_choice_must_be_known
      return if liquidity_choice.nil? || liquidity_choice == AUTOMATIC || liquidity_choice.in?(LEVELS)

      errors.add(:liquidity, :inclusion)
    end
end
