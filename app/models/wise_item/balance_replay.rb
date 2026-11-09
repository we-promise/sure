# frozen_string_literal: true

# Replays Wise balances from zero through the rows Sure stores for them, to
# work out what neither /v1/transfers nor the activity feed says:
#
# - Whether a balance paid an outgoing transfer at all. Wise also takes a
#   transfer's money from a card or a bank, and both payloads look the same.
#   A payout the balance could not have paid, when it was created nor when
#   its activity last changed, was funded externally ("wise_funding").
# - How much each balance paid of a card payment Wise split across several
#   balances; the secondaryAmount lists only their currencies ("GBP, EUR").
#   The balance in the merchant's currency pays first, so it is drained to
#   zero. The other balances' parts come out of what each has left over at
#   the end (its running balance minus the live amount), oldest payment
#   first: each part at most the balance's lowest point until its next such
#   payment (low-water rule), the last one taking the rest, and none more
#   than the rest of the payment at the nearest known exchange rate plus a
#   fee allowance ("wise_split_parts", and "wise_split_estimated" for the
#   currencies that paid more than one such payment). A payment one of whose
#   parts no exchange rate bounds gets none: a debit Sure does not book
#   would pass for that part.
#
# A balance reconciles only when the replay with those results never goes
# below zero and ends at the live amount. The importer then replaces the
# marks on that balance's rows; any other balance keeps what it had. So does
# one whose leftover went into a split payment's part that is not written
# (#funding_withheld), as a credit Sure misses could hide there, and it
# reconciles only when its split parts fit the funding marks it keeps
# (#marks_that_fit). The replay itself ignores the marks already on the
# rows: it always starts from what Wise reported.
class WiseItem::BalanceReplay
  ANNOTATION_KEYS = %w[wise_funding wise_split_parts wise_split_estimated].freeze
  EXTERNAL_FUNDING = "external"

  # Rounding the replay tolerates at every step and at the end.
  TOLERANCE = BigDecimal("0.01")
  # A balance short of a payout's gross by more than this did not pay it
  # (WiseEntry::Processor::FEE_THRESHOLD).
  SHORTFALL = BigDecimal("0.005")
  # Fees Wise may charge on top of a split payment: 3 % plus 2 units of the
  # payment's currency.
  FEE_ALLOWANCE_SHARE = BigDecimal("0.03")
  FEE_ALLOWANCE_UNITS = BigDecimal("2")
  # How far a split part's own exchange rate may stray from the nearest one.
  RATE_MARGIN = BigDecimal("1.1")
  # Days around a payment within which a rate Sure stored is used.
  STORED_RATE_DAYS = 5
  ZERO = BigDecimal("0")

  # key: the caller's id for the balance; live: what Wise holds now (amount
  # plus reservedAmount); rows: the balance's stored payload rows.
  Balance = Data.define(:key, :currency, :live, :rows)

  # reason: nil when the balance reconciled. funding_withheld: why it keeps
  # its funding marks although it reconciled (#funding_withheld), or nil.
  # counts: its rows by role, for support. notes: e.g. split parts no
  # exchange rate could bound.
  Outcome = Data.define(:key, :currency, :reason, :funding_withheld, :counts, :notes) do
    def success? = reason.nil?
  end

  # funding: { balance key => ids of its externally funded transfers }, for
  # the balances that reconciled and whose funding is not withheld.
  # split_annotations: { activity id =>
  # { "wise_split_parts" => {...}, "wise_split_estimated" => [...] or nil } },
  # for the split payments whose every balance reconciled.
  Result = Data.define(:outcomes, :funding, :split_annotations)

  # One movement of a balance. amount is unsigned: what a credit, debit or
  # refund moved, a payout's gross debit, or a split payment's full amount
  # in the merchant's currency (currency).
  Flow = Struct.new(:kind, :at, :amount, :id, :currency, :settle_at, :payout_id, :funding_currencies, keyword_init: true) do
    def credit? = kind == :credit || kind == :refund
    def split? = kind == :split_primary || kind == :split_secondary

    # Timestamps in order, except that within one second credits come first:
    # a transfer's creation time has no fractions, so a payout must not sort
    # before the conversion that paid for it.
    def sort_key = [ at.to_i, credit? ? 0 : 1, at, id ]
  end

  # A rate Sure already holds (no provider call): the nearest within
  # STORED_RATE_DAYS, read in either direction, else the cross rate through
  # a currency Sure holds rates for with both (such as the family's, which
  # every account's balance converts to). nil when there is none.
  def self.stored_rate(from, to, date)
    window = (date - STORED_RATE_DAYS)..(date + STORED_RATE_DAYS)
    rates = ExchangeRate.where(date: window).where("from_currency IN (:pair) OR to_currency IN (:pair)", pair: [ from, to ]).to_a
    direct = nearest_rate(rates, from, to, date)
    return direct if direct

    pivots = rates.flat_map { |rate| [ rate.from_currency, rate.to_currency ] }.uniq - [ from, to ]
    pivots.sort.each do |pivot|
      from_pivot = nearest_rate(rates, from, pivot, date)
      to_pivot = nearest_rate(rates, to, pivot, date)
      return from_pivot / to_pivot if from_pivot && to_pivot
    end
    nil
  end

  # Units of `to` per unit of `from` from the nearest of the given rates for
  # the pair, read in either direction.
  def self.nearest_rate(rates, from, to, date)
    [ [ from, to, false ], [ to, from, true ] ].each do |source, target, inverse|
      stored = rates.select { |rate| rate.from_currency == source && rate.to_currency == target }.min_by { |rate| (rate.date - date).abs }
      rate = stored&.rate&.to_d
      return inverse ? 1 / rate : rate if rate&.positive?
    end
    nil
  end
  private_class_method :nearest_rate

  def self.fee_allowance(amount)
    amount * FEE_ALLOWANCE_SHARE + FEE_ALLOWANCE_UNITS
  end

  # balances: the balances to replay, one per currency. own_recipient_ids:
  # see WiseItem#own_recipient_ids. feed: rows to read exchange rates from
  # (by default the balances' own). stored_rate: the fallback rate lookup.
  def initialize(balances, own_recipient_ids:, feed: nil, stored_rate: self.class.method(:stored_rate))
    @balances = balances
    @own_recipient_ids = own_recipient_ids
    @feed = feed || balances.flat_map(&:rows)
    @stored_rate = stored_rate
  end

  def call
    ledgers = @balances.map { |balance| Ledger.new(balance, own_recipient_ids: @own_recipient_ids) }
    ledgers.each(&:forward_pass)
    merchant_parts = ledgers.reject(&:failed?).map(&:drains).reduce({}, :merge)
    ledgers.each { |ledger| ledger.allocate_parts { |flow| part_limit(flow, ledger.currency, merchant_parts) } }
    ledgers.each(&:final_check)
    annotations, withheld = marks_that_fit(ledgers)

    Result.new(
      outcomes: ledgers.map { |ledger| ledger.outcome(funding_withheld: withheld[ledger]) },
      funding: ledgers.reject { |ledger| ledger.failed? || withheld[ledger] }.to_h { |ledger| [ ledger.balance.key, ledger.externals.dup ] },
      split_annotations: annotations
    )
  end

  # One balance's replay.
  class Ledger
    attr_reader :balance, :reason, :flows, :externals, :drains

    def initialize(balance, own_recipient_ids:)
      @balance = balance
      @own_recipient_ids = own_recipient_ids
      @externals = Set.new
      @drains = {}
      @parts = {}
      @unbounded = Set.new
      @secondaries = []
      @notes = {}
      @flows = balance.rows.flat_map { |row| flows_for(row.except(*ANNOTATION_KEYS)) }.sort_by(&:sort_key)
      # The processors would book such a row in another currency.
      fail!(:foreign_currency_row) if @flows.any? { |flow| !flow.split? && flow.currency != currency }
    end

    def currency
      balance.currency
    end

    def failed?
      !reason.nil?
    end

    # The running balance's upper bound: other balances' unknown parts of
    # split payments count as nothing. A payout the balance cannot pay when
    # created waits until its activity last changed (credits arriving in the
    # meantime count); still unpaid then, it was funded externally.
    def forward_pass
      return if failed?

      running = ZERO
      waiting = []
      flows.each_with_index do |flow, index|
        running = settle(waiting, running) { |payout| payout.settle_at < flow.at }
        case flow.kind
        when :credit
          running += flow.amount
        when :refund
          running = settle(waiting, running) { |payout| payout.id == flow.payout_id }
          running += flow.amount unless externals.include?(flow.payout_id)
        when :debit
          running -= flow.amount
        when :payout
          if running >= flow.amount - SHORTFALL
            running -= flow.amount
          else
            waiting << flow
          end
        when :split_primary
          # Wise splits a payment only when this balance cannot pay it all.
          return fail!(:split_payment_affordable) if running > flow.amount + WiseItem::BalanceReplay.fee_allowance(flow.amount)

          drains[flow.id] = [ running, ZERO ].max
          running -= drains[flow.id]
        when :split_secondary
          @secondaries << [ flow, index ]
        end
      end
      @upper_bound = settle(waiting, running) { true }
    end

    # What this balance paid of split payments in other currencies: the
    # leftover, oldest payment first, each part at most the lowest running
    # balance from that payment until the next one (parts already taken
    # included), the last one taking the rest. The block gives a part's
    # plausible maximum, or nil when no rate bounds it (#unbounded?).
    def allocate_parts
      return if failed?

      leftover = @upper_bound - balance.live
      if @secondaries.empty?
        fail!(:leftover_unexplained) if leftover.abs > TOLERANCE
        return
      end
      return fail!(:leftover_negative) if leftover < -TOLERANCE

      running = running_balances
      taken = ZERO
      @secondaries.each_with_index do |(flow, index), position|
        following = @secondaries[position + 1]
        part = following ? [ leftover - taken, running[index...following.last].min - taken ].min : leftover - taken
        part = [ part, ZERO ].max
        limit = yield(flow)
        if limit.nil?
          @unbounded << flow.id if part > TOLERANCE
          @notes[:unbounded_part_count] = @unbounded.size if @unbounded.any?
        elsif part > limit
          return fail!(:implausible_split_part)
        end
        @parts[flow.id] = part
        taken += part
      end
    end

    # The replay with its results applied must never go below zero and must
    # end at the live amount.
    def final_check
      return if failed?

      running = running_balances(@parts)
      return fail!(:negative_running_balance) if running.any? { |value| value < -TOLERANCE }

      fail!(:live_amount_mismatch) if ((running.last || ZERO) - balance.live).abs > TOLERANCE
    end

    # This balance's part of a split payment, or nil when it had none.
    def part(id)
      drains[id] || @parts[id]
    end

    def estimated?(id)
      @secondaries.size > 1 && @parts.key?(id)
    end

    # Its part of the split payment is more than nothing, and no exchange
    # rate bounds it.
    def unbounded?(id)
      @unbounded.include?(id)
    end

    def outcome(funding_withheld: nil)
      Outcome.new(key: balance.key, currency: currency, reason: reason, funding_withheld: funding_withheld, counts: counts,
                  notes: @notes)
    end

    # The payouts its rows already mark as externally funded, as they stay
    # when its funding marks are withheld. A mark on a row that books no
    # payout changes nothing, so it does not count.
    def marked_externals
      payouts = flows.filter_map { |flow| flow.id if flow.kind == :payout }
      balance.rows.filter_map { |row| row["id"].to_s if row["wise_funding"] == EXTERNAL_FUNDING }.to_set & payouts
    end

    # Its split parts do not fit the funding marks it keeps
    # (WiseItem::BalanceReplay#marks_that_fit).
    def funding_unconfirmed!
      fail!(:funding_unconfirmed)
    end

    private

      def fail!(reason)
        @reason ||= reason
        nil
      end

      def counts
        {
          flow_count: flows.size,
          payout_count: flows.count { |flow| flow.kind == :payout },
          external_candidate_count: externals.size,
          drained_split_count: drains.size,
          secondary_split_count: @secondaries.size
        }
      end

      def settle(waiting, running)
        waiting.select { |payout| yield(payout) }.each do |payout|
          waiting.delete(payout)
          if running < payout.amount - SHORTFALL
            externals << payout.id
          else
            running -= payout.amount
          end
        end
        running
      end

      # The running balance after each flow, externally funded payouts left
      # out, drained parts and the given other-currency parts applied.
      def running_balances(parts = {})
        running = ZERO
        flows.map do |flow|
          running += case flow.kind
          when :credit then flow.amount
          when :refund then externals.include?(flow.payout_id) ? ZERO : flow.amount
          when :debit then -flow.amount
          when :payout then externals.include?(flow.id) ? ZERO : -flow.amount
          when :split_primary then -drains.fetch(flow.id, ZERO)
          when :split_secondary then -parts.fetch(flow.id, ZERO)
          end
        end
      end

      # The movements a stored row books on this balance, as the processors
      # book them (see WiseAccount::Transactions::Processor#processor_for).
      def flows_for(row)
        return [] if row["wise_statement"].present?
        return activity_flows(row) if WiseActivity::Processor.activity_row?(row)

        row["id"].present? ? transfer_flows(row) : []
      end

      # WiseEntry::Processor: an outgoing transfer debits sourceValue plus its
      # fee (the gross) and a refunded one credits its refund; a pay-in
      # credits targetValue. A row the processor cannot date books nothing.
      def transfer_flows(row)
        direction = WiseEntry::Processor.direction(row, own_recipient_ids: @own_recipient_ids)
        return [] if WiseEntry::Processor.skip_reason(row, direction: direction)

        at = parse_time { WiseEntry::Processor.created_at(row) }
        return [] unless at

        id = row["id"].to_s
        if direction == :incoming
          return [ Flow.new(kind: :credit, at: at, amount: row["targetValue"].to_d.abs, id: id,
                            currency: row["targetCurrency"].presence || currency) ]
        end

        source_currency = row["sourceCurrency"].presence || currency
        activity = row["wise_activity"].is_a?(Hash) ? row["wise_activity"] : {}
        updated_at = parse_time { ActiveSupport::TimeZone["UTC"].parse(activity["updatedOn"].to_s) if activity["updatedOn"].present? }
        flows = [ Flow.new(kind: :payout, at: at, amount: row["sourceValue"].to_d.abs + WiseEntry::Processor.fee(row), id: id,
                           currency: source_currency, settle_at: [ at, updated_at ].compact.max) ]
        refund = WiseEntry::Processor.refund(row) if row["status"] == WiseEntry::Processor::REFUNDED_STATUS
        if refund
          flows << Flow.new(kind: :refund, at: refund[:created_at] || at, amount: refund[:value], id: "#{id}/refund",
                            currency: refund[:currency] || source_currency, payout_id: id)
        end
        flows
      end

      # WiseActivity::Processor books completed activities only.
      def activity_flows(row)
        return [] unless row["status"].to_s == WiseActivity::Processor::BOOKED_STATUS

        at = parse_time { WiseActivity::Processor.created_at(row) }
        return [] unless at

        if WiseActivity::Processor::TWO_LEG_TYPES.include?(row["type"].to_s)
          conversion_flows(row, at)
        else
          single_leg_flows(row, at)
        end
      end

      def conversion_flows(row, at)
        primary = WiseActivity::Processor.parse_amount(row["primaryAmount"])
        secondary = WiseActivity::Processor.parse_amount(row["secondaryAmount"])
        conversion = WiseActivity::Processor.conversion_currencies(row)
        kind, amount, flow_currency =
          if conversion && conversion[:source] == currency
            [ :debit, secondary[:value], currency ]
          elsif conversion && conversion[:target] == currency
            [ :credit, primary[:value], currency ]
          else
            # A move between the balance and a jar, booked by its title.
            [ WiseActivity::Processor.jar_deposit?(row) ? :debit : :credit, primary[:value], primary[:currency] || currency ]
          end
        [ Flow.new(kind: kind, at: at, amount: amount || ZERO, id: row["id"].to_s, currency: flow_currency) ]
      end

      def single_leg_flows(row, at)
        funding = WiseActivity::Processor.balance_amount(row)
        return [] unless funding

        id = row["id"].to_s
        if funding[:split]
          return [] unless funding[:currencies].include?(currency)

          kind = funding[:currency] == currency ? :split_primary : :split_secondary
          return [ Flow.new(kind: kind, at: at, amount: funding[:value] || ZERO, id: id, currency: funding[:currency],
                            funding_currencies: funding[:currencies]) ]
        end

        [ Flow.new(kind: funding[:direction] == :credit ? :credit : :debit, at: at, amount: funding[:value] || ZERO, id: id,
                   currency: funding[:currency] || currency) ]
      end

      def parse_time
        yield
      rescue ArgumentError
        nil
      end
  end

  private

    # The most a balance can have paid of a split payment in another
    # currency: the rest after the merchant-currency part, with RATE_MARGIN
    # and the fee allowance, at the nearest known rate. nil without a rate.
    # (Without the merchant-currency part, the rest is the whole payment, but
    # then that balance did not reconcile and no part is written.)
    def part_limit(flow, currency, merchant_parts)
      rate = exchange_rate(from: flow.currency, to: currency, at: flow.at)
      return nil unless rate

      rest = [ flow.amount - merchant_parts.fetch(flow.id, ZERO), ZERO ].max
      (rest * RATE_MARGIN + self.class.fee_allowance(flow.amount)) * rate
    end

    # Units of `to` per unit of `from`: from the nearest completed conversion
    # or auto-converted card payment between the two, else a stored rate.
    def exchange_rate(from:, to:, at:)
      nearest = rate_points.fetch([ from, to ], []).min_by { |point| (point[:at] - at).abs }
      nearest ? nearest[:rate] : @stored_rate.call(from, to, at.utc.to_date)
    end

    def rate_points
      @rate_points ||= @feed.uniq { |row| row["id"] }.each_with_object({}) do |row, points|
        next unless rate_row?(row)

        at = parse_time { WiseActivity::Processor.created_at(row) }
        primary = WiseActivity::Processor.parse_amount(row["primaryAmount"])
        secondary = WiseActivity::Processor.parse_amount(row["secondaryAmount"])
        next unless at && primary[:value]&.positive? && secondary[:value]&.positive?
        next if primary[:currency].blank? || secondary[:currency].blank? || primary[:currency] == secondary[:currency]

        (points[[ primary[:currency], secondary[:currency] ]] ||= []) << { at: at, rate: secondary[:value] / primary[:value] }
        (points[[ secondary[:currency], primary[:currency] ]] ||= []) << { at: at, rate: primary[:value] / secondary[:value] }
      end
    end

    def rate_row?(row)
      return false unless WiseActivity::Processor.activity_row?(row) && row["status"] == WiseActivity::Processor::BOOKED_STATUS

      type = row["type"].to_s
      WiseActivity::Processor::TWO_LEG_TYPES.include?(type) ||
        (WiseActivity::Processor::SINGLE_LEG_TYPES.include?(type) && WiseActivity::Processor.direction(row) == :debit)
    end

    # Why a balance that reconciled keeps its funding marks: what it held
    # beyond its live amount went into a share of a split payment (its own
    # drained part, or another currency's rest) that is not written, as not
    # every balance the payment lists reconciled or one of its parts has no
    # rate to bound it (:split_parts_withheld). A credit Sure misses would
    # then pass for a payout the balance could not pay. nil when nothing went
    # into such a share.
    def funding_withheld(ledger, annotations)
      return nil if ledger.failed?

      paid = ledger.flows.select { |flow| flow.split? && (ledger.part(flow.id) || ZERO) > TOLERANCE }
      :split_parts_withheld if paid.any? { |flow| !annotations.key?(flow.id) }
    end

    # The split annotations, and per balance why it keeps its funding marks
    # (#funding_withheld). Such a balance's split parts were worked out with
    # the payouts its replay took as externally funded, so they fit the marks
    # it keeps only when those mark the same payouts. Otherwise they would
    # book a payout's money twice (the payout and a part holding it) or not
    # at all, so it does not reconcile (:funding_unconfirmed) and its split
    # payments keep their parts, which can withhold another balance's
    # funding in turn.
    def marks_that_fit(ledgers)
      loop do
        annotations = split_annotations(ledgers)
        withheld = ledgers.to_h { |ledger| [ ledger, funding_withheld(ledger, annotations) ] }
        unfit = ledgers.select { |ledger| withheld[ledger] && ledger.externals != ledger.marked_externals }
        return [ annotations, withheld ] if unfit.empty?

        unfit.each(&:funding_unconfirmed!)
      end
    end

    # A split payment's parts are written only when every balance it lists
    # reconciled, so its copies on those balances never disagree, and a rate
    # bounded each part.
    def split_annotations(ledgers)
      reconciled = ledgers.reject(&:failed?).index_by(&:currency)
      ledgers.flat_map { |ledger| ledger.flows.select(&:split?) }.group_by(&:id).each_with_object({}) do |(id, flows), annotations|
        currencies = flows.first.funding_currencies
        next unless currencies.all? { |currency| reconciled.key?(currency) }
        next if currencies.any? { |currency| reconciled[currency].unbounded?(id) }

        parts = currencies.to_h { |currency| [ currency, reconciled[currency].part(id) ] }
        next if parts.values.any?(&:nil?)

        annotations[id] = {
          "wise_split_parts" => parts.to_h { |currency, part| [ currency, decimal_string(part, currency) ] },
          "wise_split_estimated" => currencies.select { |currency| reconciled[currency].estimated?(id) }.presence
        }
      end
    end

    def decimal_string(value, currency)
      precision = begin
        Money::Currency.new(currency).default_precision
      rescue Money::Currency::UnknownCurrencyError
        2
      end
      whole, fraction = value.round(precision).to_s("F").split(".")
      precision.zero? ? whole : "#{whole}.#{fraction.to_s.ljust(precision, "0")}"
    end

    def parse_time
      yield
    rescue ArgumentError
      nil
    end
end
