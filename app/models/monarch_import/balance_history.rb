# Works out the balance valuations Sure needs to reproduce an account's
# Monarch balance history.
#
# Sure's forward calculator carries a balance from day to day by applying
# transactions, and a valuation sets the balance outright on its date. So a
# valuation is only needed where Monarch's balance differs from what the
# transactions already give. Everything here uses Monarch's signs: balances
# are negative for amounts owed, and flows are net transaction amounts with
# inflows positive.
#
# An account that already exists in Sure brings its own entries. Its
# valuations are fixed: where one disagrees with Monarch on the same day,
# Sure's value is kept and the day is reported as a conflict. Its transactions
# count toward the balance like imported ones.
class MonarchImport::BalanceHistory
  attr_reader :conflicts

  def initialize(history:, flows: {}, closed: false, existing_valuations: {}, existing_flows: {})
    @history = history
    @flows = flows
    @closed = closed
    @existing_valuations = existing_valuations
    @existing_flows = existing_flows
    @conflicts = []
  end

  # [[date, balance]] in date order. The first is the opening balance.
  def anchors
    @anchors ||= compute_anchors
  end

  # The anchors, adjusted so the balance on as_of equals balance. Nothing is
  # added when the history already ends at that balance.
  def anchors_with_current_balance(as_of, balance)
    return anchors if replay(through: as_of)[as_of] == balance

    if @existing_valuations.key?(as_of)
      @conflicts << as_of unless @existing_valuations[as_of] == balance
      return anchors
    end

    (anchors.reject { |date, _| date == as_of } + [ [ as_of, balance ] ]).sort_by(&:first)
  end

  # { date => balance } the way Sure's forward calculator derives it, from the
  # first entry through the last (or through, when later).
  def replay(anchors = self.anchors, through: nil)
    valuations = @existing_valuations.merge(anchors.to_h)
    flows = combined_flows
    dates = valuations.keys + flows.keys
    return {} if dates.empty?

    last = [ dates.max, through ].compact.max
    running = BigDecimal("0")
    dates.min.upto(last).each_with_object({}) do |date, balances|
      running = valuations.fetch(date) { running + flows.fetch(date, 0) }
      balances[date] = running
    end
  end

  private
    def combined_flows
      @combined_flows ||= @flows.merge(@existing_flows) { |_, imported, existing| imported + existing }
    end

    def compute_anchors
      flows = combined_flows
      return [] if @history.empty? && @flows.empty?

      anchors = []
      running = nil

      first_balance_date = @history.keys.min
      first_flow_date = @flows.keys.min

      if first_flow_date && (first_balance_date.nil? || first_flow_date < first_balance_date) &&
          no_existing_valuation_through?(first_balance_date)
        # Transactions predate the balance history: work backwards from the
        # first known balance so the earlier transactions land on the right
        # total.
        opening = if first_balance_date
          @history[first_balance_date] - flows.sum { |date, amount| date <= first_balance_date ? amount : 0 }
        else
          BigDecimal("0")
        end
        anchors << [ first_flow_date - 1, opening ]
        running = opening
      end

      (@history.keys | flows.keys | @existing_valuations.keys).sort.each do |date|
        if @existing_valuations.key?(date)
          running = @existing_valuations[date]
          @conflicts << date if @history.key?(date) && @history[date] != running
          next
        end

        expected = running && running + flows.fetch(date, 0)
        actual = @history[date]
        if actual && actual != expected
          anchors << [ date, actual ]
          running = actual
        else
          running = expected
        end
      end

      if @closed && @history.any?
        last_date = @history.keys.max
        if @history[last_date].nonzero? && flows.keys.none? { |date| date > last_date }
          anchors << [ last_date + 1, BigDecimal("0") ]
        end
      end

      anchors
    end

    def no_existing_valuation_through?(date)
      date.nil? || @existing_valuations.keys.none? { |existing| existing <= date }
    end
end
