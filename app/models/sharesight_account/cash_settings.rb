# Where a portfolio's cash lives, and where its dividends go.
#
# cash_mode
#   broker      The broker holds the cash (the default). Top-ups from a funding
#               account can be mirrored in, and you can give a balance for cash
#               Sharesight can't see.
#   settlement  Trades settle against another account from settlement_starts_on
#               (the broker had the cash before that). The investment account
#               only shows shares.
#   untracked   Shares only, the cash isn't tracked anywhere.
#
# dividend_mode
#   with_cash      Goes wherever the cash is: kept by the broker, or paid out to
#                  the settlement account (or outside Sure).
#   other_account  Paid out to dividend_account.
#   skip           Not imported, because another connection already has them.
module SharesightAccount::CashSettings
  extend ActiveSupport::Concern

  CASH_MODES = %w[broker settlement untracked].freeze
  DIVIDEND_MODES = %w[with_cash other_account skip].freeze
  MAX_SETTLEMENT_WINDOW_DAYS = 30

  SETTINGS_ATTRIBUTES = %i[
    cash_mode settlement_account_id settlement_starts_on settlement_window_days
    dividend_mode dividend_account_id funding_account_id funding_match_terms
    cash_anchor_amount cash_anchor_on sync_start_date
  ].freeze

  # Money that went somewhere Sure doesn't track.
  OUTSIDE = :outside

  included do
    belongs_to :settlement_account, class_name: "Account", optional: true
    belongs_to :dividend_account, class_name: "Account", optional: true
    belongs_to :funding_account, class_name: "Account", optional: true

    validates :cash_mode, inclusion: { in: CASH_MODES }
    validates :dividend_mode, inclusion: { in: DIVIDEND_MODES }
    validates :settlement_window_days, numericality: { only_integer: true, in: 0..MAX_SETTLEMENT_WINDOW_DAYS }
    validate :settlement_account_present
    validate :dividend_account_present
    validate :cash_anchor_complete
    validate :other_accounts_belong_to_family
  end

  # Settings from the account form. Blank ids and dates clear the setting, and
  # the funding terms come in as one comma-separated string.
  def assign_cash_settings(attributes)
    attributes = attributes.to_h.symbolize_keys.slice(*SETTINGS_ATTRIBUTES)
    attributes.transform_values! { |value| value.presence }
    if attributes.key?(:funding_match_terms)
      attributes[:funding_match_terms] = attributes[:funding_match_terms].to_s.split(",").map(&:strip).reject(&:blank?).uniq
    end
    attributes[:settlement_window_days] ||= 7 if attributes.key?(:settlement_window_days)
    attributes[:cash_mode] ||= "broker" if attributes.key?(:cash_mode)
    attributes[:dividend_mode] ||= "with_cash" if attributes.key?(:dividend_mode)

    assign_attributes(attributes)
  end

  def cash_settings_changed?
    (saved_changes.keys & SETTINGS_ATTRIBUTES.map(&:to_s)).any?
  end

  def holds_cash_at_broker_on?(date)
    case cash_mode
    when "broker" then true
    when "settlement" then settlement_starts_on.present? && date < settlement_starts_on
    else false
    end
  end

  # Where a trade on this date settles. nil while the broker has the cash,
  # otherwise the settlement account (or OUTSIDE).
  def trade_destination_on(date)
    return nil if holds_cash_at_broker_on?(date)

    (cash_mode == "settlement" && settlement_account) || OUTSIDE
  end

  # Where a dividend paid on this date goes. nil if the broker keeps it, :skip
  # if we're not importing them, otherwise an account (or OUTSIDE).
  def dividend_destination_on(date)
    case dividend_mode
    when "skip" then :skip
    when "other_account" then dividend_account || OUTSIDE
    else trade_destination_on(date)
    end
  end

  def dividends_skipped?
    dividend_mode == "skip"
  end

  def funding_terms
    Array(funding_match_terms).map { |term| term.to_s.strip }.reject(&:blank?)
  end

  def cash_anchor?
    cash_anchor_amount.present? && cash_anchor_on.present?
  end

  def before_sync_start?(date)
    sync_start_date.present? && date.present? && date < sync_start_date
  end

  private

    def settlement_account_present
      return unless cash_mode == "settlement" && settlement_account_id.blank?

      errors.add(:base, I18n.t("sharesight_accounts.errors.settlement_account_missing"))
    end

    def dividend_account_present
      return unless dividend_mode == "other_account" && dividend_account_id.blank?

      errors.add(:base, I18n.t("sharesight_accounts.errors.dividend_account_missing"))
    end

    def cash_anchor_complete
      return if cash_anchor_amount.present? == cash_anchor_on.present?

      errors.add(:base, I18n.t("sharesight_accounts.errors.cash_anchor_incomplete"))
    end

    def other_accounts_belong_to_family
      family = sharesight_item&.family
      own_account_id = account_provider&.account_id

      [ settlement_account, dividend_account, funding_account ].compact.each do |other|
        if other.family_id != family&.id
          errors.add(:base, I18n.t("sharesight_accounts.errors.account_not_in_family", name: other.name))
        elsif other.id == own_account_id
          errors.add(:base, I18n.t("sharesight_accounts.errors.account_is_portfolio", name: other.name))
        end
      end
    end
end
