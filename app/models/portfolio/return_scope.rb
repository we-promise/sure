# What return method an account's data can actually support.
#
# This exists so the engine cannot quote a
# figure the underlying records do not justify: a manually valued account has no
# record of what was paid in, so a money-weighted return over its flows would be
# a fabrication, and an account with one day of history has no return at all.
#
# Deliberately evaluated BEFORE the metrics rather than filtered afterwards --
# a suppression rule applied at the view layer is one refactor away from being
# forgotten.
class Portfolio::ReturnScope
  # The account records buys, sells or transfers, so its external flows are
  # known and every method is available.
  TRADE_TRACKED = :trade_tracked

  # The account's value is asserted by valuations. Its change over time is a
  # value return; its flows are unknown, so no money-weighted return.
  VALUATION_TRACKED = :valuation_tracked

  # Fewer than two days of balance history in the period: no return exists.
  INSUFFICIENT = :insufficient

  KINDS = [ TRADE_TRACKED, VALUATION_TRACKED, INSUFFICIENT ].freeze

  attr_reader :account, :period, :active_until_date

  # `active_until_date` is the account's cut-off, as Portfolio::DailyReturns
  # takes it: the last day the account contributes to the series. Rows after it
  # are dropped there, so they are not counted here either -- an account with
  # two rows in the period and the second past its cut-off has one usable day,
  # and one day supports no return. The same bound ends the history every
  # tracking check reads: a trade, valuation or transfer after the cut-off
  # records a flow the series never sees. nil means no cut-off.
  #
  # `resolved` carries the four inputs when a caller has already fetched them
  # for a set of accounts. Everything below still derives `kind` from those four
  # by the same rules, so the batch path cannot mean something different from
  # the lazy one -- it only skips the fetching. Built directly, the instance
  # queries for each input as before.
  def initialize(account:, period:, active_until_date: nil, resolved: nil)
    @account = account
    @period = period
    @active_until_date = active_until_date&.to_date

    return if resolved.nil?

    @balance_days = resolved.fetch(:balance_days)
    @trades = resolved.fetch(:trades)
    @valuations = resolved.fetch(:valuations)
    @external_transactions = resolved.fetch(:external_transactions)
  end

  # Eligibility for a set of accounts, keyed by account id, in a fixed number of
  # round trips rather than up to four per account.
  #
  # Four, not three: loading the accounts, then the three resolution queries.
  # The load is part of the work, because the resolver hands back ReturnScope
  # objects that hold the record and `Portfolio::Performance` carries only ids,
  # so nothing earlier in the call has already fetched them. What the batch path buys is
  # that the four do not grow with the number of accounts -- pinned by
  # "resolve_all asks the same number of queries however many accounts it is
  # given".
  #
  # Takes Account RECORDS -- a relation, or an array of them, which may include
  # closed and disabled accounts; Performance passes
  # `Account.where(id: account_ids)`.
  #
  # Not ids. Passing them raises NoMethodError on the first `records.map(&:id)`,
  # which is the intended answer: normalising them here would mean a load whose
  # existence depends on the shape of the argument, so the query count this
  # method advertises would stop being a property of the method. A caller that
  # holds ids converts them, and pays for it where it can be seen.
  #
  # `active_until_dates` is { account_id => cut-off } in the shape
  # Portfolio::DailyReturns takes, nil values meaning no cut-off, and every
  # check reads each account's history only up to its own cut-off -- the same
  # rule the instance applies. The cut-offs ride inside the existing queries,
  # so they add none.
  def self.resolve_all(accounts:, period:, active_until_dates: {})
    records = accounts.to_a
    return {} if records.empty?

    cutoffs = (active_until_dates || {}).compact
      .transform_keys(&:to_s)
      .transform_values(&:to_date)

    days = balance_days_by_account(records, period, cutoffs)
    kinds = live_entry_kinds_by_account(records, period, cutoffs)
    external = external_transaction_account_ids(records, period, cutoffs)

    records.to_h do |account|
      resolved = {
        # An account with no rows in the period gets no GROUP BY row. It must
        # default to zero rather than go missing: `balance_days.zero?` is a
        # load-bearing case at both Performance call sites, where it means
        # "holds nothing here, so it neither contributes nor withholds".
        balance_days: days.fetch(account.id, 0),
        trades: kinds.include?([ account.id, "Trade" ]),
        valuations: kinds.include?([ account.id, "Valuation" ]),
        external_transactions: external.include?(account.id)
      }

      [ account.id, new(account: account, period: period, active_until_date: cutoffs[account.id.to_s], resolved: resolved) ]
    end
  end

  # Balance rows are counted in each account's OWN currency, as the instance
  # does. Grouping over `balances` alone would count every currency the account
  # holds, so the account is joined and the currencies compared.
  #
  # The cut-offs go in as one JSON object read per row, the way DailyReturns
  # binds them, so a set with cut-offs still costs this one query.
  def self.balance_days_by_account(records, period, cutoffs)
    Balance
      .joins(:account)
      .where(account_id: records.map(&:id), date: period.date_range)
      .where("balances.currency = accounts.currency")
      .where(
        "(CAST(:cutoffs AS jsonb) ->> balances.account_id::text) IS NULL " \
        "OR balances.date <= (CAST(:cutoffs AS jsonb) ->> balances.account_id::text)::date",
        cutoffs: cutoffs.transform_values(&:iso8601).to_json
      )
      .group(:account_id)
      .count
  end
  private_class_method :balance_days_by_account

  # trades? and valuations? read the same rows, so one query answers both.
  # The cut-offs bind as the balance query binds them.
  def self.live_entry_kinds_by_account(records, period, cutoffs)
    Entry
      .where(account_id: records.map(&:id), entryable_type: %w[Trade Valuation])
      .where("COALESCE(entries.excluded, false) = false")
      .where("entries.date <= ?", period.end_date)
      .where(
        "(CAST(:cutoffs AS jsonb) ->> entries.account_id::text) IS NULL " \
        "OR entries.date <= (CAST(:cutoffs AS jsonb) ->> entries.account_id::text)::date",
        cutoffs: cutoffs.transform_values(&:iso8601).to_json
      )
      .distinct
      .pluck(:account_id, :entryable_type)
      .to_set
  end
  private_class_method :live_entry_kinds_by_account

  # One round trip, but one fragment per account: each account has to be its
  # OWN classifier scope, exactly as the instance builds it. Classifying the
  # whole set together would make a transfer between two accounts in the set
  # `internal`, and an account whose only external flow is a transfer to a
  # sibling would fall from TRADE_TRACKED to VALUATION_TRACKED -- Performance
  # would then withhold a money-weighted return it should quote. FlowClassifier bakes
  # its scope into a fixed ARRAY literal, so the scope cannot vary per row.
  #
  # Each fragment carries its own account's history end, the earlier of the
  # period end and its cut-off, as `history_end_date` computes it.
  def self.external_transaction_account_ids(records, period, cutoffs)
    connection = ActiveRecord::Base.connection

    fragments = records.map do |account|
      classifier = Portfolio::FlowClassifier.new(scope_account_ids: [ account.id ])
      quoted_id = connection.quote(account.id)
      quoted_end_date = connection.quote([ period.end_date, cutoffs[account.id.to_s] ].compact.min)

      # Values are quoted rather than bound: sanitize_sql_array would scan the
      # classifier's finished CASE for `:name` placeholders, and the CASE
      # carries every label literal.
      <<~SQL
        SELECT #{quoted_id} AS account_id
        WHERE EXISTS (
          SELECT 1
          FROM entries
          #{classifier.sql_joins}
          WHERE entries.account_id = #{quoted_id}
            AND entries.entryable_type = 'Transaction'
            AND entries.date <= #{quoted_end_date}
            AND COALESCE(entries.excluded, false) = false
            AND #{classifier.sql_case} IN ('external_inflow', 'external_outflow')
        )
      SQL
    end

    connection.select_values(fragments.join(" UNION ALL ")).to_set
  end
  private_class_method :external_transaction_account_ids

  def kind
    @kind ||= begin
      if balance_days < 2
        INSUFFICIENT
      elsif trades? || external_transactions?
        TRADE_TRACKED
      elsif valuations?
        VALUATION_TRACKED
      else
        # Balances exist but nothing explains them. Treated as valuation-tracked:
        # the value change is real and reportable, the flows are not known.
        VALUATION_TRACKED
      end
    end
  end

  def insufficient? = kind == INSUFFICIENT
  def trade_tracked? = kind == TRADE_TRACKED
  def valuation_tracked? = kind == VALUATION_TRACKED

  def supports_time_weighted_return?
    !insufficient?
  end

  # Only an account whose flows are known supports a money-weighted return.
  def supports_money_weighted_return?
    trade_tracked?
  end

  # The i18n key suffix the UI uses to label the figure, so a valuation-tracked
  # account is never captioned "time-weighted return".
  def return_label_key
    valuation_tracked? ? "value_return" : "time_weighted_return"
  end

  # Balance rows in the account's currency inside the period, up to the
  # account's cut-off. Public so a caller weighing several accounts can tell
  # one that holds nothing in the period (no rows, nothing to withhold) from
  # one with a single day, which has no return.
  def balance_days
    @balance_days ||= begin
      rows = account.balances.where(currency: account.currency, date: period.date_range)
      rows = rows.where(date: ..active_until_date) if active_until_date
      rows.count
    end
  end

  private
    # The last day any tracking check reads: the period end, or the account's
    # cut-off when that comes first. A cut-off later than the period end is a
    # bound, never an extension.
    def history_end_date
      [ period.end_date, active_until_date ].compact.min
    end

    # Every tracking check reads the same records: the account's live entries
    # up to `history_end_date`. Live means not excluded, as
    # Portfolio::FlowClassifier reads it, and `entries.excluded` is nullable,
    # so NULL counts as live through COALESCE. History before the period
    # counts, because flows known from earlier are still known inside
    # it.
    def live_entries_through_history_end
      account.entries
        .where("COALESCE(entries.excluded, false) = false")
        .where("entries.date <= ?", history_end_date)
    end

    def trades?
      return @trades if defined?(@trades)
      @trades = live_entries_through_history_end.where(entryable_type: "Trade").exists?
    end

    # A transfer in or out is as good as a trade for knowing the flows.
    #
    # One query through the classifier's SQL form rather than the Ruby form per
    # entry: the Ruby form looks up transfers and counterparts row by row, which
    # over an account's whole history is a round trip per transaction. The two
    # forms are held to agree by the classifier's parity test.
    def external_transactions?
      return @external_transactions if defined?(@external_transactions)

      # The account is its own scope here: this asks whether money crossed
      # *this* account's boundary, so a transfer to a sibling account is
      # external from where this question is asked.
      classifier = Portfolio::FlowClassifier.new(scope_account_ids: [ account.id ])
      sql = <<~SQL
        SELECT EXISTS (
          SELECT 1
          FROM entries
          #{classifier.sql_joins}
          WHERE entries.account_id = :account_id
            AND entries.entryable_type = 'Transaction'
            AND entries.date <= :end_date
            AND COALESCE(entries.excluded, false) = false
            AND #{classifier.sql_case} IN ('external_inflow', 'external_outflow')
        )
      SQL

      # No :scope_account_ids bind: the classifier sanitizes the scope into its
      # own fragment rather than leaving a placeholder for the caller to fill.
      value = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([
          sql, { account_id: account.id, end_date: history_end_date }
        ])
      )
      @external_transactions = ActiveModel::Type::Boolean.new.cast(value) == true
    end

    def valuations?
      return @valuations if defined?(@valuations)
      @valuations = live_entries_through_history_end.where(entryable_type: "Valuation").exists?
    end
end
