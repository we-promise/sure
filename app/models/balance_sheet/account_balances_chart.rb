# Data for the dashboard's Account Balances widget: each account's balance
# history in the family currency over a period, and a forecast from today's
# recorded balance moved by the bills (active recurring transactions,
# including income and transfers) and the transactions already recorded with
# a future date. Liabilities come out negative so the chart can stack them
# below zero.
#
# Bills are limited to the accounts the viewing user may access: a bill on a
# private account never appears, not even as a bill without an account.
class BalanceSheet::AccountBalancesChart
  FORECAST_MONTHS = 12
  UNASSIGNED_ID = "unassigned".freeze

  def initialize(family, user:, accounts:, period:, today: Date.current)
    @family = family
    @user = user
    @accounts = accounts.to_a.sort_by { |a| [ a.liability? ? 1 : 0, a.accountable_type, -a.balance.to_d.abs ] }
    @period = period
    @today = today
    @horizon = today + FORECAST_MONTHS.months
    @currency = family.currency
  end

  def to_h
    @to_h ||= build
  end

  def bill_count
    viewable_bills.size
  end

  private
    attr_reader :family, :user, :accounts, :period, :today, :horizon, :currency

    def build
      history = accounts.to_h { |a| [ a.id, history_for(a) ] }
      dates = history.values.flat_map(&:keys).uniq.sort
      events = bill_events
      future_transaction_events.each { |account_id, list| events[account_id].concat(list) }
      balances_today = recorded_balances_today

      series = accounts.map do |account|
        {
          id: account.id,
          name: account.name,
          type: account.accountable_type,
          type_label: account_type_label(account.accountable_type),
          color: Accountable.from_type(account.accountable_type)&.color || Category::UNCATEGORIZED_COLOR,
          liability: account.liability?,
          history: forward_filled(dates.map { |date| history[account.id][date] }),
          start: signed_balance(account, balances_today[account.id]).to_f.round(2),
          events: (events.delete(account.id) || []).sort_by { |e| e[:date] }
        }
      end

      # Bills with no account, or on an accessible account that is not
      # charted (e.g. disabled), get their own layer starting at zero.
      unassigned = events.values.flatten
      if unassigned.any?
        series << {
          id: UNASSIGNED_ID, name: I18n.t("pages.dashboard.account_balances.unassigned"), type: "Unassigned",
          type_label: I18n.t("pages.dashboard.account_balances.unassigned_group"), color: Category::UNCATEGORIZED_COLOR,
          liability: false, history: dates.map { 0 }, start: 0, events: unassigned.sort_by { |e| e[:date] }
        }
      end

      {
        currency: currency,
        # The family's own number and date conventions, so the chart formats like the rest of Sure.
        money_format: Money.new(0, currency).format_options.slice(:unit, :delimiter, :separator, :format),
        date_format: family.date_format,
        today: today.iso8601,
        horizon: horizon.iso8601,
        dates: dates.map(&:iso8601),
        accounts: series
      }
    end

    # Balance::ChartSeriesBuilder handles currency conversion, gaps and the
    # period's interval. With favorable_direction "up" a liability comes out
    # negative (net of assets minus liabilities), which is what the stack wants.
    def history_for(account)
      Balance::ChartSeriesBuilder.new(
        account_ids: [ account.id ], currency: currency, period: period, favorable_direction: "up"
      ).balance_series.values.to_h { |v| [ v.date.to_date, v.value.amount.to_f.round(2) ] }
    end

    # A day missing from one account's series would drop its layer to zero
    # for that day and cut a sliver through the stack.
    def forward_filled(values)
      last = values.compact.first || 0
      values.map { |v| last = v.nil? ? last : v }
    end

    # Account#balance already includes future-dated entries; the forecast
    # adds those on their own dates, so it starts from today's recorded balance.
    def signed_balance(account, recorded_today)
      amount = to_family_currency((recorded_today || account.balance).to_d, account.currency)
      account.liability? ? -amount : amount
    end

    def recorded_balances_today
      Balance.where(account_id: accounts.map(&:id), date: ..today)
             .select("DISTINCT ON (balances.account_id) balances.account_id, balances.end_balance")
             .order("balances.account_id, balances.date DESC")
             .to_h { |b| [ b.account_id, b.end_balance ] }
    end

    def account_type_label(type)
      Accountable.from_type(type)&.display_name || type
    end

    def to_family_currency(amount, from_currency)
      return amount if from_currency.blank? || from_currency == currency

      Money.new(amount, from_currency).exchange_to(currency).amount
    rescue Money::ConversionError
      amount
    end

    # Every account a bill names (source and, for transfers, destination)
    # must be accessible to the viewer; bills with no account stay in.
    def viewable_bills
      @viewable_bills ||= begin
        accessible = user.accessible_accounts.pluck(:id).to_set
        family.recurring_transactions.active.includes(:recurrence_rules).to_a.select do |bill|
          [ bill.account_id, bill.destination_account_id ].compact.all? { |id| accessible.include?(id) }
        end
      end
    end

    def occurrences_by_bill
      @occurrences_by_bill ||= begin
        bills = viewable_bills.index_by(&:id)
        rows = RecurringOccurrence.where(recurring_transaction_id: bills.keys).to_a
        rows.each { |occurrence| occurrence.association(:recurring_transaction).target = bills[occurrence.recurring_transaction_id] }
        RecurringOccurrence.preload_confirmed_allocated(rows.select(&:scheduled?))
        rows.group_by(&:recurring_transaction_id)
      end
    end

    # { account_id => [ { date:, amount:, name:, source: } ] }, amount being
    # the signed change to the account as charted: an outflow is negative for
    # liabilities too (a card charge makes its negative layer deeper).
    def bill_events
      charted = accounts.map(&:id).to_set
      events = Hash.new { |hash, key| hash[key] = [] }
      bucket = ->(account_id) { charted.include?(account_id) ? account_id : UNASSIGNED_ID }

      viewable_bills.each do |bill|
        bill_occurrences(bill).each do |date, amount|
          amount = to_family_currency(amount, bill.currency).to_f.round(2)
          next if amount.zero?

          event = { date: date.iso8601, name: bill.display_name, source: "bill" }
          if bill.typed_transfer? && bill.destination_account_id
            events[bucket.(bill.account_id)] << event.merge(amount: -amount) if bill.account_id
            events[bucket.(bill.destination_account_id)] << event.merge(amount: amount)
          else
            inflow = bill.typed_income? || bill.amount.negative?
            events[bucket.(bill.account_id)] << event.merge(amount: inflow ? amount : -amount)
          end
        end
      end

      events
    end

    # Sure stores outflows as positive amounts; the chart wants the change.
    def future_transaction_events
      Entry.where(account_id: accounts.map(&:id), entryable_type: "Transaction", date: (today + 1)..horizon)
           .group_by(&:account_id).transform_values do |entries|
        entries.map do |entry|
          { date: entry.date.iso8601, amount: to_family_currency(-entry.amount.to_d, entry.currency).to_f.round(2),
            name: entry.name, source: "transaction" }
        end
      end
    end

    # [[date, positive amount]] between today and the horizon. Materialized
    # open occurrences come first: they carry skips, snoozes, amount
    # overrides and partial payments. The schedule extends past the last
    # materialized one. Overdue unpaid occurrences are left out, since a bill
    # that is never matched to a payment would otherwise pile up on day one.
    def bill_occurrences(bill)
      rows = occurrences_by_bill.fetch(bill.id, [])
      upcoming = rows.select(&:scheduled?).filter_map do |occurrence|
        due = occurrence.effective_due_on
        next unless due >= today && due <= horizon

        remaining = occurrence.resolved_expected_amount.to_d - occurrence.confirmed_allocated.to_d
        [ due, remaining ] if remaining.positive?
      end

      materialized_through = rows.map(&:original_due_on).max
      from = [ materialized_through ? materialized_through + 1 : today, today ].max
      if from <= horizon
        amount = projected_amount(bill)
        RecurringTransaction::Schedule.for(bill).occurrences_between(from, horizon).each { |date| upcoming << [ date, amount ] }
      end

      upcoming
    end

    def projected_amount(bill)
      amount = bill.amount_average? ? (bill.expected_amount_avg.presence || bill.amount) : bill.amount
      amount.to_d.abs
    end
end
