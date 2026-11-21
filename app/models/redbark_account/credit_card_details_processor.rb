# frozen_string_literal: true

# Fills a credit card's blank APR from the product details the bank publishes
# through `GET /v1/account-details`.
#
# FILL-BLANK ONLY, unlike Plaid, which writes the APR on every sync. Plaid's
# figure is the issuer's for this account; Redbark's `lendingRates` describe the
# PRODUCT. A value already on the card -- typed, imported or restored -- is at
# least as good evidence as a product sheet, so this only fills a gap.
#
# The annual fee is deliberately not read: `fees` publishes the product's
# ceiling ("the Annual Fee that may apply is up to ..."), not what this
# account is charged.
#
# `lendingRate` is not read: its meaning for a card is undocumented. The
# PURCHASE entries in `lendingRates` are the rate that applies to spending.
# A 0% purchase rate is taken as promotional and not recorded.
#
# A card's details are fetched at most once per REFRESH_WINDOW, and any
# payload stored within it is used, so a day that fails to process is retried
# on the next sync. Warnings are logged once per window (see .warn_once).
class RedbarkAccount::CreditCardDetailsProcessor
  SOURCE = "redbark"
  REFRESH_WINDOW = 7.days

  attr_reader :redbark_account, :as_of

  # Shared with RedbarkItem::Importer, which fetches details only for these.
  def self.needs_apr?(card)
    card.apr.blank? && !card.locked?(:apr)
  end

  # Logs a warning unless the same source and message were already logged for
  # `key` (a redbark_account_id, or a redbark_item_id for a whole batch) in
  # the last REFRESH_WINDOW, so a lasting problem is reported once, not every
  # sync.
  def self.warn_once(message, source:, family:, key:, **metadata)
    logged = DebugLogEntry.where(source: source, message: message)
                          .where(created_at: REFRESH_WINDOW.ago..)
                          .where("metadata @> ?", key.to_json)
    return if logged.exists?

    DebugLogEntry.capture(
      category: "provider_sync",
      level: "warn",
      message: message,
      source: source,
      provider_key: "redbark",
      family: family,
      metadata: metadata.merge(key)
    )
  end

  def initialize(redbark_account, as_of:)
    @redbark_account = redbark_account
    @as_of = as_of
  end

  # Never raises: an unexpected payload is logged so the rest of the sync
  # still runs.
  def process
    return unless card
    return unless self.class.needs_apr?(card)
    return if details.blank?
    return unless details_fetched_recently?

    rate = purchase_rate
    write(apr: rate) if rate
  rescue StandardError => e
    warn_once("Redbark card details could not be processed (#{e.class.name})", message: e.message)
  end

  private
    # The APR is only ever filled where blank, so a payload from earlier in
    # the window is as good as one from today.
    def details_fetched_recently?
      fetched_at = redbark_account.account_details_fetched_at
      return false if fetched_at.blank?

      redbark_account.redbark_item.family.local_date(fetched_at) > as_of.to_date - REFRESH_WINDOW
    end

    def card
      return @card if defined?(@card)

      account = redbark_account.current_account
      @card = account&.accountable_type == "CreditCard" ? account.accountable : nil
    end

    def details
      @details ||= redbark_account.raw_account_details_payload&.deep_symbolize_keys || {}
    end

    # A bank may list the purchase rate more than once, so agreement is judged
    # on distinct values. A tiered entry is several rates in one, keyed to a
    # balance the payload does not give, so it is left out rather than allowed
    # to disagree. A blank or unparseable entry is skipped, not a veto.
    def purchase_rate
      entries = Array(details[:lendingRates]).select do |entry|
        entry.is_a?(Hash) &&
          entry[:rateType].to_s.casecmp("PURCHASE").zero? &&
          Array(entry[:tiers]).empty?
      end

      values = entries.filter_map { |entry| parse_decimal(entry[:rate]) }
      return nil if values.empty?

      distinct = values.uniq
      if distinct.size > 1
        warn_once("Redbark reported several purchase rates for a card; recording none", rates: distinct.map(&:to_s).sort)
        return nil
      end

      to_percentage(distinct.first)
    end

    # The API reports fractions: "0.1999" is 19.99%. `credit_cards.apr` is a
    # percentage with two decimal places.
    def to_percentage(decimal)
      rate = (decimal * 100).round(2)
      if rate.zero?
        warn_once("Redbark reported a 0% purchase rate for a card; taking it as promotional")
        return nil
      end
      return rate if rate.between?(0, 100)

      warn_once("Redbark reported a card rate outside 0..100%; ignoring it", value: decimal.to_s)
      nil
    end

    def parse_decimal(value)
      return nil if value.blank?

      decimal = BigDecimal(value.to_s)
      raise ArgumentError, "not finite" unless decimal.finite?

      decimal
    rescue ArgumentError, TypeError
      warn_once("Redbark reported an unparseable card rate", value: value.to_s)
      nil
    end

    # Through Enrichable, as the loan processor writes: locked attributes are
    # skipped and provenance is recorded. A refusal is rolled back and logged
    # rather than raised, so it cannot fail the sync.
    def write(attrs)
      ActiveRecord::Base.transaction do
        card.enrich_attributes(attrs, source: SOURCE)
        raise ActiveRecord::Rollback if card.errors.any?
      end
      return if card.errors.empty?

      capture(
        "Redbark card detail refused by the model",
        credit_card_id: card.id,
        attributes: attrs.keys.map(&:to_s),
        errors: card.errors.full_messages
      )
      card.restore_attributes(attrs.keys.map(&:to_s))
      card.errors.clear
    end

    def warn_once(message, **metadata)
      self.class.warn_once(
        message, source: self.class.name, family: redbark_account.redbark_item&.family,
        key: { redbark_account_id: redbark_account.id }, **metadata
      )
    end

    def capture(message, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "redbark",
        family: redbark_account.redbark_item&.family,
        metadata: metadata.merge(redbark_account_id: redbark_account.id)
      )
    end
end
