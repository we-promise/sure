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
# no job flips the column. Predicates therefore take the date
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

  def liquidity_manual?
    locked?(:liquidity)
  end

  def default_liquidity
    return "immediate" if accountable_class.nil?

    accountable_class.rules_for(subtype).liquidity
  end

  # Whether the money can be reached on `date` (today by default). Named
  # apart from `available_on?`, the attribute query Rails generates for the
  # `available_on` column; the API returns it as `available_now`.
  def available_now?(date = liquidity_today)
    return false if liability?
    return true if liquidity.in?(AVAILABLE_LEVELS)

    liquidity == "locked" && !auto_renew? && available_on.present? && available_on <= date
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
      # A type with a fixed level always follows its default, also when a
      # choice arrives through the API or an import.
      @liquidity_choice = AUTOMATIC if Accountable.from_type(accountable_type)&.liquidity_selectable? == false

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
