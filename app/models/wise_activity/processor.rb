# frozen_string_literal: true

class WiseActivity::Processor
  # Conversions between two of the profile's own balances. Wise credits the
  # primary amount to one balance and debits the secondary from another, with
  # no markup, so they have no single direction.
  TWO_LEG_TYPES = %w[INTERBALANCE AUTO_CONVERSION].freeze

  # Money one balance paid or received that, without balance statements,
  # only the activity feed reports: card payments and their refunds, cash
  # withdrawals, direct debits, cashback and rewards, adjustments, card
  # acquiring, and the card and account-details order fees.
  SINGLE_LEG_TYPES = %w[
    CARD_PAYMENT CASH_WITHDRAWAL DIRECT_DEBIT_TRANSACTION CARD_CASHBACK REWARD
    BALANCE_ADJUSTMENT ACQUIRING_PAYMENT CARD_ORDER BANK_DETAILS_ORDER
  ].freeze

  # The activity of a transfer. For a /v1/transfers transfer it only enriches
  # that transfer; a credit for a transfer Sure does not have (a bank payment
  # into the account details, money from another Wise profile) is booked like
  # a single-leg activity (see WiseItem::Importer#activity_route).
  TRANSFER_TYPES = %w[TRANSFER BALANCE_DEPOSIT].freeze

  # Interest, cashback and fees on what a balance holds, which belong to a
  # jar or an invested balance in their currency.
  HOLDING_TYPES = %w[BALANCE_INTEREST BALANCE_CASHBACK BALANCE_ASSET_FEE BALANCE_HOLD_FEE].freeze

  # Types that only ever pay money in: an unmarked amount is still a credit.
  CREDIT_ONLY_TYPES = %w[REWARD CARD_CASHBACK BALANCE_INTEREST BALANCE_CASHBACK].freeze

  # Only a completed activity moved money. Wise also lists IN_PROGRESS (a card
  # hold), UPCOMING, REQUIRES_ATTENTION and CANCELLED (a declined payment)
  # ones; they are stored so a later status is seen, but book nothing.
  BOOKED_STATUS = "COMPLETED"

  # At least one digit, so the comma in a split-funding list such as
  # "GBP, EUR" is not read as an amount of 0.
  AMOUNT_PATTERN = /\d[\d,]*(?:\.\d+)?/
  CURRENCY_PATTERN = /\b[A-Z]{3}\b/

  # Splits a Wise amount string like "<positive>+ 1,000.50 EUR</positive>"
  # into [BigDecimal value, currency code]. Either part is nil when absent.
  def self.parse_money(str)
    parse_amount(str).values_at(:value, :currency)
  end

  # INTERBALANCE covers both Jar moves and currency conversions between the
  # profile's own balances; AUTO_CONVERSION is a conversion Wise made on its
  # own. For a conversion Wise reports the target amount as primaryAmount and
  # the source amount as secondaryAmount, so the two currencies differ.
  def self.conversion_currencies(activity)
    return nil unless TWO_LEG_TYPES.include?(activity["type"].to_s)

    target = parse_money(activity["primaryAmount"]).last
    source = parse_money(activity["secondaryAmount"]).last
    return nil if source.blank? || target.blank? || source == target

    { source: source, target: target }
  end

  # Reads a Wise amount string. The value is unsigned; Wise marks direction
  # with markup instead: a top-up is "<positive>+ 2,465 GBP</positive>" and a
  # card refund "<positive>+ 0.64 EUR</positive>", while debits are usually
  # unmarked ("1,618.42 USD"). A card payment split across balances lists
  # only their currencies ("GBP, EUR"), with no amount.
  #
  #   parse_amount("<positive>+ 2,465 GBP</positive>")
  #   # => { value: 2465, currency: "GBP", currencies: ["GBP"], marked: :positive, sign: 1 }
  #   parse_amount("GBP, EUR")
  #   # => { value: nil, currency: "GBP", currencies: ["GBP", "EUR"], marked: nil, sign: nil }
  def self.parse_amount(str)
    raw = str.to_s
    text = ActionController::Base.helpers.strip_tags(raw).strip
    currencies = text.scan(CURRENCY_PATTERN).uniq
    marked =
      if raw.match?(/<positive>/i) then :positive
      elsif raw.match?(/<negative>/i) then :negative
      elsif text.start_with?("+") then :positive
      elsif text.start_with?("-") then :negative
      end

    {
      value: text[AMOUNT_PATTERN]&.delete(",")&.to_d,
      currency: currencies.first,
      currencies: currencies,
      marked: marked,
      sign: { positive: 1, negative: -1 }[marked]
    }
  end

  # :credit or :debit for a single-leg activity, nil for a conversion (see
  # TWO_LEG_TYPES). The type alone cannot tell: a CARD_PAYMENT can be a
  # refund and a TRANSFER a top-up, so a positive mark on either amount makes
  # a credit, and only the credit-only types are credits without one.
  def self.direction(activity)
    type = activity["type"].to_s
    return nil if TWO_LEG_TYPES.include?(type)

    marks = [ activity["primaryAmount"], activity["secondaryAmount"] ].map { |str| parse_amount(str)[:marked] }
    return :credit if marks.include?(:positive)
    return :debit if marks.include?(:negative)

    CREDIT_ONLY_TYPES.include?(type) ? :credit : :debit
  end

  # A debit Wise drew from several balances without saying how much from
  # each: its secondary lists the currencies but has no amount.
  def self.split?(activity)
    direction(activity) == :debit && split_funding?(parse_amount(activity["secondaryAmount"]))
  end

  # What a single-leg activity moved on the balance it touched, unsigned,
  # with its direction. Wise puts the amount it credited in primaryAmount.
  # For a debit the primary is what the merchant or recipient received and
  # the secondary, when it has an amount, is what left the balance: the gross
  # including fees, or the paying balance's side of an auto-conversion.
  # A split debit (see .split?) returns the primary, in the merchant's
  # currency, with the funding currencies it lists. nil for conversions.
  #
  #   balance_amount("type" => "CARD_PAYMENT", "primaryAmount" => "7.40 EUR", "secondaryAmount" => "6.42 GBP")
  #   # => { value: 6.42, currency: "GBP", direction: :debit, split: false, currencies: ["GBP"] }
  def self.balance_amount(activity)
    direction = direction(activity)
    return nil unless direction

    primary = parse_amount(activity["primaryAmount"])
    secondary = parse_amount(activity["secondaryAmount"])
    split = direction == :debit && split_funding?(secondary)
    booked = (direction == :debit && secondary[:value]) ? secondary : primary

    {
      value: booked[:value],
      currency: booked[:currency],
      direction: direction,
      split: split,
      currencies: split ? secondary[:currencies] : [ booked[:currency] ].compact
    }
  end

  # A stored activity row, as opposed to a /v1/transfers or a statement row.
  def self.activity_row?(row)
    row["wise_statement"].blank? && row["createdOn"].present? && row["resource"].present?
  end

  # createdOn is a UTC ISO-8601 timestamp ("2026-09-16T22:41:38.553Z").
  # Order activities by this instant; book them on its family-zone date.
  def self.created_at(activity)
    raw = activity["createdOn"]
    ActiveSupport::TimeZone["UTC"].parse(raw.to_s) if raw.present?
  end

  # A Wise title such as "<strong>Tom &amp; Jerry</strong>" as plain text
  # ("Tom & Jerry"): strip_tags alone leaves the entities escaped.
  def self.plain_text(html)
    CGI.unescapeHTML(ActionController::Base.helpers.strip_tags(html.to_s)).strip
  end

  # Whether a move between a balance and a jar went into the jar, which
  # only its title tells ("To <strong>Holiday</strong>").
  def self.jar_deposit?(activity)
    title = ActionController::Base.helpers.strip_tags(activity["title"].to_s).downcase
    title.start_with?("to") || title.include?("received") || title.include?("added")
  end

  def self.split_funding?(parsed)
    parsed[:value].nil? && parsed[:currencies].size >= 2
  end
  private_class_method :split_funding?

  def initialize(activity, wise_account:)
    @activity = activity.with_indifferent_access
    @wise_account = wise_account
  end

  def process
    unless account.present?
      Rails.logger.warn "WiseActivity::Processor - No linked account for wise_account #{wise_account.id}, skipping #{safe_id}"
      return :skipped
    end

    if skip_reason
      Rails.logger.debug "WiseActivity::Processor - Skipping activity #{safe_id} on wise_account #{wise_account.id}: #{skip_reason}"
      return :skipped
    end

    import_entry(
      external_id: external_id,
      amount: amount,
      currency: currency,
      date: date,
      name: name,
      source: "wise",
      extra: extra,
      # extra[:wise] is the full snapshot, so a flag Wise stops reporting clears.
      replace_extra_namespaces: [ "wise" ]
    )
  rescue ArgumentError => e
    Rails.logger.error "WiseActivity::Processor - Validation error for activity #{safe_id}: #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WiseActivity::Processor - Error for activity #{safe_id}: #{e.class} - #{e.message}"
    raise
  end

  # The external ids of the entries processing this activity keeps on its
  # balance: none when it books nothing there (not completed, another
  # balance's share of a split payment, or carried by a statement row now),
  # so an entry it booked earlier is stale.
  def expected_external_ids
    skip_reason ? [] : [ external_id ]
  end

  # What the activity books on this balance, { external_id:, amount:,
  # currency: } with Sure's sign (positive = money out), or nil when it
  # books nothing here. Needs no linked account.
  def booking
    { external_id: external_id, amount: amount, currency: currency } unless skip_reason
  end

  # The day the activity books on, whether it books here or not; nil when
  # it has no readable date.
  def booking_date
    date if account.present?
  rescue ArgumentError
    nil
  end

  private

    attr_reader :activity, :wise_account

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    # Imports through the adapter; Wise's amount also reaches an entry a
    # person acted on (WiseItem::AmountCorrection).
    def import_entry(**attributes)
      entry = import_adapter.import_transaction(**attributes)
      WiseItem::AmountCorrection.apply(entry, amount: attributes[:amount], currency: attributes[:currency])
    end

    def account
      @account ||= wise_account.current_account
    end

    # Why the activity books nothing on this balance, or nil when it books.
    # A statement row that carries its movement books it instead
    # ("wise_superseded_by", see WiseItem::StatementMigration).
    def skip_reason
      return @skip_reason if defined?(@skip_reason)

      @skip_reason =
        if activity[:wise_superseded_by].present?
          :superseded
        elsif activity[:status].to_s != BOOKED_STATUS
          :status
        elsif split? && split_amount.nil?
          :split_paid_elsewhere
        end
    end

    # Conversions use resource_id so both sides can be matched for Transfer
    # linking. Other activity types use the opaque activity id.
    def external_id
      if two_leg?
        side = wise_account.jar? || conversion_target? ? "inflow" : "outflow"
        "wise_interbalance_#{resource_id}_#{side}"
      else
        "wise_activity_#{activity[:id]}"
      end
    end

    def two_leg?
      TWO_LEG_TYPES.include?(activity_type)
    end

    def safe_id
      activity[:id].presence || "unknown"
    end

    def activity_type
      activity[:type].to_s
    end

    def resource_id
      activity.dig(:resource, :id).to_s
    end

    def conversion
      return @conversion if defined?(@conversion)

      @conversion = wise_account.jar? ? nil : self.class.conversion_currencies(activity)
    end

    def conversion_source?
      conversion.present? && conversion[:source] == wise_account.currency
    end

    def conversion_target?
      conversion.present? && conversion[:target] == wise_account.currency
    end

    # Expenses (outflow) → positive in Sure.
    # Incomes (inflow / interest) → negative in Sure.
    def amount
      return amount_value(activity[:secondaryAmount]) if conversion_source?
      return -amount_value(activity[:primaryAmount]) if conversion_target?
      return single_leg_amount unless two_leg?

      raw = amount_value(activity[:primaryAmount])
      if wise_account.jar?
        # JAR perspective: "To Jar" = deposit (income, negative)
        deposit_direction? ? -raw : raw
      else
        # STANDARD perspective: "To Jar" = outflow (expense, positive)
        deposit_direction? ? raw : -raw
      end
    end

    # The sign comes from Wise's markup (see .direction), not from the type.
    def single_leg_amount
      value = split? ? split_amount : (single_leg[:value] || 0.to_d)
      single_leg[:direction] == :credit ? -value : value
    end

    def single_leg
      @single_leg ||= self.class.balance_amount(activity) ||
        raise(ArgumentError, "Wise activity #{safe_id} (#{activity_type}) moves money between two balances")
    end

    # A debit Wise drew from several balances (see .split?). The importer
    # stores it on each of them.
    def split?
      !two_leg? && single_leg[:split]
    end

    # This balance's share of a split debit: the part the balance replay
    # worked out ("wise_split_parts", { currency => decimal string }), or
    # without one the whole merchant amount on one balance the payment lists
    # (#unresolved_split_currency), a documented limitation for items
    # without a replay. nil when this balance books nothing.
    def split_amount
      return @split_amount if defined?(@split_amount)

      @split_amount =
        if split_parts
          part = split_parts[wise_account.currency].presence&.to_d
          part if part&.positive?
        elsif unresolved_split_currency == wise_account.currency
          single_leg[:value]
        end
    end

    # The balance a split debit without parts books in full on, in the
    # merchant's currency: the merchant-currency one, or the first Wise
    # lists when it drew on no balance in that currency (a payment in a
    # currency the profile does not hold).
    def unresolved_split_currency
      listed = single_leg[:currencies]
      listed.include?(single_leg[:currency]) ? single_leg[:currency] : listed.first
    end

    def split_parts
      parts = activity[:wise_split_parts]
      parts if parts.is_a?(Hash) && parts.present?
    end

    # The balance replay marks a part estimated ("wise_split_estimated", the
    # list of currencies whose parts it estimated, or true for all of them).
    def split_estimated?
      estimated = activity[:wise_split_estimated]
      estimated == true || (estimated.is_a?(Array) && estimated.include?(wise_account.currency))
    end

    # True when the activity title indicates money flowing INTO the JAR.
    def deposit_direction?
      self.class.jar_deposit?(activity)
    end

    def currency
      return conversion[:source] if conversion_source?
      return conversion[:target] if conversion_target?
      # A split part is in the currency of the balance that paid it; the
      # whole payment, without parts, in the merchant's.
      return split_parts ? wise_account.currency : single_leg[:currency] if split?
      return single_leg[:currency] || wise_account.currency unless two_leg?

      self.class.parse_amount(activity[:primaryAmount])[:currency] || wise_account.currency
    end

    def name
      jar_name = wise_account.jar? ? (wise_account.raw_payload&.dig("name") || "Jar") : nil

      case activity_type
      when *TWO_LEG_TYPES
        if conversion_source?
          I18n.t("wise_items.activities.transfer_to_jar", jar: conversion[:target])
        elsif conversion_target?
          I18n.t("wise_items.activities.transfer_from_jar", jar: conversion[:source])
        elsif wise_account.jar?
          deposit_direction? ? I18n.t("wise_items.activities.jar_deposit") : I18n.t("wise_items.activities.jar_withdrawal")
        else
          deposit_direction? ? I18n.t("wise_items.activities.transfer_to_jar", jar: jar_name_for_standard) : I18n.t("wise_items.activities.transfer_from_jar", jar: jar_name_for_standard)
        end
      when "BALANCE_CASHBACK", "BALANCE_INTEREST"
        I18n.t("wise_items.activities.interest")
      when "BALANCE_ASSET_FEE"
        I18n.t("wise_items.activities.asset_fee")
      else
        self.class.plain_text(activity[:title]).presence ||
          I18n.t("wise_items.activities.default_name")
      end
    end

    def jar_name_for_standard
      activity[:title].to_s.scan(/<strong>([^<]+)<\/strong>/).flatten.last || "Jar"
    end

    # The date in the family's zone (WiseItem#time_zone), as for transfers
    # and statement rows: 23:52 UTC on 11 August is 12 August in Dublin (IST).
    def date
      raw = activity[:createdOn].presence
      raise ArgumentError, "Activity missing createdOn" unless raw

      created_at = self.class.created_at(activity)
      raise ArgumentError, "Unable to parse createdOn #{raw.inspect}" unless created_at

      created_at.in_time_zone(wise_account.wise_item.time_zone).to_date
    end

    # The full wise namespace on every import (flags clear when false).
    def extra
      split = split?

      {
        wise: {
          activity_id: activity[:id],
          activity_type: activity_type,
          resource_type: activity.dig(:resource, :type),
          resource_id: resource_id.presence,
          description: activity[:description].presence,
          primary_amount: activity[:primaryAmount].presence,
          secondary_amount: activity[:secondaryAmount].presence,
          split_part: (true if split && split_parts),
          split_estimated: (true if split && split_parts && split_estimated?),
          split_unresolved: (true if split && !split_parts)
        }.compact
      }
    end

    # The unsigned amount in strings like:
    #   "1,000 EUR"                          → 1000.0
    #   "<positive>+ 1.12 EUR</positive>"    → 1.12
    #   "0.83 EUR"                           → 0.83
    def amount_value(raw)
      self.class.parse_amount(raw)[:value] || 0.to_d
    end
end
