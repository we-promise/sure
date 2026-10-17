# frozen_string_literal: true

class WiseEntry::Processor
  # What a transfer's status means for the balance it books on. Once Wise has
  # funded a payout from the balance, the balance stays debited while Wise
  # processes, converts, sends, waits for the recipient or holds a bounced
  # payout. A pay-in reaches the balance only once Wise has sent it. Nothing
  # else books: incoming_payment_* (not funded yet), cancelled (never
  # funded), charged_back (returned to the payer) and unknown. A refunded
  # payout books only together with its refund credit.
  OUTGOING_BOOKED_STATUSES = %w[
    outgoing_payment_sent processing funds_converted bounced_back waiting_recipient_input_to_proceed
  ].freeze
  INCOMING_BOOKED_STATUSES = %w[outgoing_payment_sent].freeze
  REFUNDED_STATUS = "funds_refunded"

  # The statuses Wise documents with a meaning Sure acts on. Any other status,
  # Wise's own "unknown" included, books nothing and is reported.
  KNOWN_STATUSES = %w[
    incoming_payment_waiting incoming_payment_initiated processing funds_converted outgoing_payment_sent
    cancelled funds_refunded bounced_back charged_back waiting_recipient_input_to_proceed
  ].freeze

  # Below half a cent, a gap between the gross debit and sourceValue is
  # rounding, not a fee.
  FEE_THRESHOLD = BigDecimal("0.005")

  # :incoming for a pay-in, a transfer into one of the profile's own
  # recipients (see WiseItem#own_recipient_ids); :outgoing for anything else.
  # Wise ends top-ups in outgoing_payment_sent like payouts, so the status
  # cannot tell them apart. Only when no recipient is known at all does the
  # transfer's activity decide: Wise marks a top-up "<positive>+ 2,465 GBP".
  def self.direction(transfer, own_recipient_ids:)
    ids = Array(own_recipient_ids).compact_blank.map(&:to_s)

    if ids.any?
      ids.include?(transfer["targetAccount"].to_s) ? :incoming : :outgoing
    elsif (activity = activity_of(transfer)) && WiseActivity::Processor.direction(activity) == :credit
      :incoming
    else
      :outgoing
    end
  end

  # How a transfer reaches a balance, or nil when it does not. A pay-in (see
  # .direction) reaches only the balance whose own account details it paid
  # into (:account_details; recipient_owners: WiseItem#balance_recipient_owners)
  # or, paid to the account recipient, the balance in its target currency;
  # any other transfer only the balance it was paid from (:currency).
  # Matching either currency would also book e.g. a GBP-funded payout to PLN
  # on the PLN balance, and Wise does not say whether a balance paid for a
  # pay-in ("send to myself"). A transfer without a currency reaches every
  # balance. The importer routes transfers by the same rule
  # (#transfer_for_account?), and a balance books only the ones it reaches.
  def self.balance_route(transfer, wise_account, own_recipient_ids:, recipient_owners:)
    incoming = direction(transfer, own_recipient_ids: own_recipient_ids) == :incoming
    owners = recipient_owners[transfer["targetAccount"].to_s] if incoming
    return (:account_details if owners.include?(wise_account.id)) if owners

    currency = incoming ? transfer["targetCurrency"] : transfer["sourceCurrency"]
    :currency if currency.blank? || currency == wise_account.currency
  end

  # Why a transfer books nothing on its balance, or nil when it books. The
  # balance replay marks a payout Wise took from a card or bank instead of
  # the balance as externally funded ("wise_funding").
  def self.skip_reason(transfer, direction:)
    return :external_funding if transfer["wise_funding"] == "external"
    return :activity_cancelled if activity_of(transfer)&.dig("status") == "CANCELLED"

    status = transfer["status"].to_s
    if direction == :incoming
      :status unless INCOMING_BOOKED_STATUSES.include?(status)
    elsif status == REFUNDED_STATUS
      :refunded_without_credit unless refund(transfer)
    else
      :status unless OUTGOING_BOOKED_STATUSES.include?(status)
    end
  end

  def self.unknown_status?(transfer)
    KNOWN_STATUSES.exclude?(transfer["status"].to_s)
  end

  # What Wise took from the balance for an outgoing transfer, in its source
  # currency. sourceValue excludes the fee, but the transfer's activity shows
  # the gross debit: as its secondary amount, or as the primary when there
  # was neither a fee nor a conversion. nil without such an amount.
  def self.gross_debit(transfer)
    activity = activity_of(transfer)
    currency = transfer["sourceCurrency"].presence
    return nil unless activity && currency

    [ activity["secondaryAmount"], activity["primaryAmount"] ].each do |raw|
      amount = WiseActivity::Processor.parse_amount(raw)
      return amount[:value] if amount[:value] && amount[:currency] == currency
    end
    nil
  end

  # The fee Wise charged an outgoing transfer on top of sourceValue: the
  # gross debit minus sourceValue, or, without the transfer's activity, the
  # same-currency gap between sourceValue and targetValue. Pay-ins carry no
  # fee for the balance they land in.
  def self.fee(transfer)
    gross = gross_debit(transfer)
    fee =
      if gross
        gross - transfer["sourceValue"].to_d
      elsif transfer["sourceCurrency"] == transfer["targetCurrency"]
        transfer["sourceValue"].to_d - transfer["targetValue"].to_d
      else
        0.to_d
      end
    fee = fee.round(4)
    fee > FEE_THRESHOLD ? fee : 0.to_d
  end

  # The money a refunded payout brought back: the credit Wise shows for it
  # (attached as "wise_refund_activity"), as { value:, currency:,
  # created_at: }, or nil when none is known. Wise may refund less than it
  # took, so the refund books on its own next to the debit.
  def self.refund(transfer)
    activity = transfer["wise_refund_activity"]
    return nil unless activity.is_a?(Hash) && activity["status"] != "CANCELLED"

    amount = WiseActivity::Processor.parse_amount(activity["primaryAmount"])
    return nil unless amount[:value]&.positive?

    created_at = begin
      WiseActivity::Processor.created_at(activity)
    rescue ArgumentError
      nil
    end
    { value: amount[:value], currency: amount[:currency], created_at: created_at }
  end

  # The activity Wise shows for a transfer, as the importer attaches it to
  # the transfer row ("wise_activity", or "wise_refund_activity" for a
  # refund credit): amounts keep Wise's markup, the title is plain text.
  def self.activity_snapshot(activity)
    {
      "id" => activity["id"],
      "type" => activity["type"],
      "status" => activity["status"],
      "primaryAmount" => activity["primaryAmount"],
      "secondaryAmount" => activity["secondaryAmount"],
      "title" => WiseActivity::Processor.plain_text(activity["title"]).presence,
      "description" => activity["description"],
      "createdOn" => activity["createdOn"],
      "updatedOn" => activity["updatedOn"]
    }.compact
  end

  def self.activity_of(transfer)
    activity = transfer["wise_activity"]
    activity if activity.is_a?(Hash)
  end
  private_class_method :activity_of

  # Wise reports `created` in UTC without a zone designator
  # ("2025-03-27 18:04:33"), so it is parsed as UTC rather than in the
  # server's zone. Order transfers by this instant; book them on its
  # family-zone date.
  def self.created_at(transfer)
    raw = transfer["created"]
    case raw
    when String then ActiveSupport::TimeZone["UTC"].parse(raw) if raw.present?
    when Time, Date then raw.in_time_zone("UTC")
    end
  end

  # own_recipient_ids, recipient_owners: WiseItem#own_recipient_ids and
  # #balance_recipient_owners, looked up when not given.
  def initialize(wise_transaction, wise_account:, own_recipient_ids: nil, recipient_owners: nil)
    @wise_transaction = wise_transaction
    @wise_account = wise_account
    @own_recipient_ids = own_recipient_ids
    @recipient_owners = recipient_owners
  end

  def process
    unless account.present?
      Rails.logger.warn "WiseEntry::Processor - No linked account for wise_account #{wise_account.id}, skipping #{safe_id}"
      return :skipped
    end

    if skip_reason
      Rails.logger.debug "WiseEntry::Processor - Skipping transfer #{safe_id}: #{skip_reason}"
      return :skipped
    end

    result = import_main_transaction

    if fee > 0
      begin
        import_fee_transaction
      rescue StandardError => e
        Rails.logger.warn "WiseEntry::Processor - Fee transaction failed for transfer #{safe_id}: #{e.message}"
      end
    end

    import_refund_transaction if refund

    result
  rescue ArgumentError => e
    Rails.logger.error "WiseEntry::Processor - Validation error for transfer #{safe_id}: #{e.message}"
    raise
  rescue => e
    Rails.logger.error "WiseEntry::Processor - Unexpected error for transfer #{safe_id}: #{e.class} - #{e.message}"
    raise
  end

  # The external ids of the entries processing this transfer keeps on its
  # balance: none when it books nothing, so an entry it booked earlier (a
  # payout Wise has since cancelled) is stale.
  def expected_external_ids
    return [] if skip_reason

    ids = [ "wise_transfer_#{transfer_id}" ]
    ids << "wise_fee_#{transfer_id}" if fee.positive?
    ids << "wise_refund_#{transfer_id}" if refund
    ids
  end

  private

    attr_reader :wise_transaction, :wise_account

    def data
      @data ||= wise_transaction.with_indifferent_access
    end

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

    def own_recipient_ids
      @own_recipient_ids ||= wise_account.wise_item.own_recipient_ids
    end

    def recipient_owners
      @recipient_owners ||= wise_account.wise_item.balance_recipient_owners
    end

    # A row stored on a balance it does not reach (.balance_route) books
    # nothing there: e.g. the funding side of a pay-in, which an older build
    # stored and which stays in the payload when an import fails before it
    # stores the payloads again.
    def skip_reason
      return @skip_reason if defined?(@skip_reason)

      @skip_reason = (:other_balance unless routed_here?) || self.class.skip_reason(data, direction: direction)
    end

    def routed_here?
      self.class.balance_route(data, wise_account, own_recipient_ids: own_recipient_ids, recipient_owners: recipient_owners).present?
    end

    def import_main_transaction
      import_entry(
        external_id: "wise_transfer_#{transfer_id}",
        amount: main_amount,
        currency: outgoing? ? source_currency : target_currency,
        date: date,
        name: name,
        source: "wise",
        extra: extra,
        # extra[:wise] is the full snapshot, so a flag Wise stops reporting
        # clears; the top-level exchange_rate is still merged.
        replace_extra_namespaces: [ "wise" ]
      )
    end

    def import_fee_transaction
      import_entry(
        external_id: "wise_fee_#{transfer_id}",
        amount: fee,
        currency: source_currency,
        date: date,
        name: I18n.t("wise_items.entries.fee_name"),
        source: "wise",
        extra: { wise: { transfer_id: transfer_id, type: "FEE" } },
        replace_extra_namespaces: [ "wise" ]
      )
    end

    # The debit and its fee stay booked, so a partial refund nets to what
    # Wise kept.
    def import_refund_transaction
      import_entry(
        external_id: "wise_refund_#{transfer_id}",
        amount: -refund[:value],
        currency: refund[:currency] || source_currency,
        date: refund[:created_at]&.in_time_zone(time_zone)&.to_date || date,
        name: I18n.t("wise_items.entries.refund_name"),
        source: "wise",
        extra: { wise: { transfer_id: transfer_id, type: "REFUND", activity_id: data.dig(:wise_refund_activity, :id) }.compact },
        replace_extra_namespaces: [ "wise" ]
      )
    end

    def transfer_id
      data[:id].presence.tap { |id| raise ArgumentError, "Wise transfer missing id" unless id }
    end

    def safe_id
      data[:id].presence || "unknown"
    end

    # The payment reference, else the counterparty Wise names in the
    # transfer's activity ("To GBP" for a top-up).
    def name
      data.dig(:details, :reference).presence || data[:reference].presence ||
        data.dig(:wise_activity, :title).to_s.strip.presence ||
        I18n.t("wise_items.entries.default_name")
    end

    # Expenses (outgoing) → positive amount in Sure convention.
    # Incomes (incoming)  → negative amount in Sure convention.
    # Incoming cross-currency transfers use targetValue (what actually arrived) not sourceValue.
    def main_amount
      if outgoing?
        data[:sourceValue].to_d.abs
      else
        -(data[:targetValue].to_d.abs)
      end
    end

    def fee
      @fee ||= outgoing? ? self.class.fee(data) : 0.to_d
    end

    # Only a refunded payout books its refund.
    def refund
      return @refund if defined?(@refund)

      @refund = (self.class.refund(data) if outgoing? && data[:status] == REFUNDED_STATUS)
    end

    def source_currency
      data[:sourceCurrency].presence || wise_account.currency
    end

    def target_currency
      data[:targetCurrency].presence || wise_account.currency
    end

    def direction
      @direction ||= self.class.direction(data, own_recipient_ids: own_recipient_ids)
    end

    def outgoing?
      direction == :outgoing
    end

    # The family's zone (WiseItem#time_zone).
    def time_zone
      wise_account.wise_item.time_zone
    end

    def date
      raw = data[:created].presence
      raise ArgumentError, "Wise transfer missing created date" unless raw

      case raw
      when String
        if raw.include?("T") || raw.include?(":")
          created_at = self.class.created_at(data)
          raise ArgumentError, "Unable to parse date #{raw.inspect}" unless created_at

          created_at.in_time_zone(time_zone).to_date
        else
          Date.parse(raw)
        end
      when Time, DateTime
        raw.in_time_zone(time_zone).to_date
      when Date then raw
      else raise ArgumentError, "Invalid date format: #{raw.inspect}"
      end
    rescue ArgumentError
      raise
    rescue => e
      raise ArgumentError, "Unable to parse date #{raw.inspect}: #{e.message}"
    end

    def extra
      {
        exchange_rate: exchange_rate,
        wise: {
          transfer_id: transfer_id,
          status: data[:status],
          direction: outgoing? ? "outgoing" : "incoming",
          source_currency: source_currency,
          source_value: data[:sourceValue],
          target_currency: target_currency,
          target_value: data[:targetValue],
          rate: data[:rate],
          fee: fee > 0 ? fee : nil,
          reference: data.dig(:details, :reference).presence || data[:reference],
          activity_id: data.dig(:wise_activity, :id)
        }.compact
      }.compact
    end

    # Wise reports the rate actually applied to the transfer (target units per
    # source unit). Balance calculators read Transaction#exchange_rate
    # (extra["exchange_rate"]) as a custom rate, so cross-currency transfers
    # routed to an account in the target currency can be converted without a
    # historical rate from the global exchange_rates table.
    def exchange_rate
      rate = data[:rate].presence
      return nil if rate.blank?

      parsed = rate.to_d
      parsed.positive? ? parsed : nil
    end
end
