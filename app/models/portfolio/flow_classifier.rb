# The one place that says what a cash movement in an investment account *is*.
#
# Every entry in an investment or crypto account is one of five things:
#
#   :external_inflow   money or assets arriving from outside the scope
#   :external_outflow  money or assets leaving the scope
#   :income            a dividend or interest payment
#   :fee               a fee or commission
#   :internal          cash turning into a security or back, or moving between
#                      places inside the scope (buy, sell, sweep, exchange, a
#                      transfer whose other leg is also in scope)
#
# Returns, allocation, income and contribution-room figures all need this
# split, and they need the same answer. Deriving it in each reader is how the
# same dividend ends up counted as income in one place and as a deposit in
# another. So one rule table lives here and both forms of the classifier --
# the Ruby #classify for tests and small sets, the SQL #sql_case for the daily
# queries a series needs -- are generated from it, with a parity test proving
# they agree.
#
# Scope is a required argument, not a default. A transfer between two
# brokerage accounts is internal to the family portfolio and external to
# either account on its own; a classifier that did not know which question
# was being asked would give the wrong family return the first time a user
# moved a position between brokers.
#
# Inputs, in the order they are consulted: whether the entry is excluded or
# pending; a transfer-fee leg; the activity label on the Trade or Transaction;
# for an unlabelled Transaction its `kind`; and for a transfer, whether the
# counterpart leg's account is inside the scope. Direction for an external
# flow comes from the Trade's quantity sign or the Transaction's amount sign
# (negative amount = money in).
#
# What a caller must do with the answer:
#
# - Sum signed amounts per class. :income and :fee are decided by the label
#   alone, not by the sign of the amount, so a margin-interest charge labelled
#   "Interest" is :income with a positive amount, and a fee rebate labelled
#   "Fee" is :fee with a negative one. A signed sum nets them correctly; a sum
#   of absolute values would count the charge as more income.
# - Scope to one family itself. Neither form filters by family: #classify_ids
#   reads whichever entry ids it is given, and scope_account_ids is taken as
#   given. Pass only ids and accounts the caller has already scoped.
# - Pass active_until_dates when the scope's membership changes over time. An
#   account is inside the scope only up to its cut-off date, so a transfer to
#   it dated after that is external, as a transfer to any account outside the
#   scope is. For a linked transfer "dated" means the counterpart leg's own
#   date, which can differ from this leg's.
class Portfolio::FlowClassifier
  CLASSES = %i[external_inflow external_outflow income fee internal].freeze

  # Activity label -> class. Two pseudo-classes resolve at classification
  # time, and both consult the link before the label: :external and :transfer
  # each become :internal when the entry is a linked Transfer whose other leg
  # is inside the scope, and an inflow or an outflow by direction otherwise.
  # A label describes what the borrower meant; a Transfer row records where
  # the money went, and between two accounts in scope it went nowhere. A nil rule means the label decides nothing and
  # the fallthrough applies (a Trade is internal; a Transaction goes by kind).
  #
  # "Exchange" is internal on both a Trade and a Transaction here, following
  # Transaction::INTERNAL_MOVEMENT_LABELS. Trade::INTERNAL_MOVEMENT_LABELS
  # excludes it because a security-for-security exchange can realise a gain;
  # that is a cost-basis question, not a cash-flow one, and this table only
  # answers the latter.
  #
  # "Reinvestment" is internal: the cash that bought the shares was a
  # dividend, but income is only counted when a separate Dividend entry
  # records it, as InvestmentStatement::Totals already assumes.
  LABEL_RULES = {
    "Dividend" => :income,
    "Interest" => :income,
    "Fee" => :fee,
    "Buy" => :internal,
    "Sell" => :internal,
    "Reinvestment" => :internal,
    "Sweep In" => :internal,
    "Sweep Out" => :internal,
    "Exchange" => :internal,
    "Contribution" => :external,
    "Withdrawal" => :external,
    "Transfer" => :transfer,
    "Other" => nil
  }.freeze

  # Every label the table knows, so a new Transaction::ACTIVITY_LABELS entry
  # without a rule fails the test that compares the two.
  def self.labels_for(klass)
    LABEL_RULES.select { |_, rule| rule == klass }.keys.freeze
  end

  # True for a `transactions` row the classifier calls pending, as SQL: the
  # rule Transaction#pending? applies, in Transaction.pending_sql's words, so
  # this class, InvestmentStatement::Totals and every other SQL reader of the
  # flag share one definition (P25). Kept as a method here so the CASE below
  # and Totals name the same thing.
  def self.pending_sql
    Transaction.pending_sql("transactions")
  end

  INCOME_LABELS = labels_for(:income)
  FEE_LABELS = labels_for(:fee)
  INTERNAL_LABELS = labels_for(:internal)
  EXTERNAL_LABELS = labels_for(:external)
  TRANSFER_LABEL = "Transfer".freeze

  attr_reader :scope_account_ids, :include_excluded, :active_until_dates

  # include_excluded: classify an excluded entry as if it were not excluded.
  # Excluding hides an entry from budgets and reports, but the balance
  # calculators still apply it (Balance::SyncCache), so a reader reconciling
  # against balances -- Portfolio::DailyReturns -- has to see it as the flow it
  # was. Split parents are excluded too and are NOT applied; that reader skips
  # them itself.
  #
  # active_until_dates: { account_id => last date in scope }. An account with
  # no entry is in scope on every date.
  def initialize(scope_account_ids:, include_excluded: false, active_until_dates: {})
    @scope_account_ids = Array(scope_account_ids).map(&:to_s).uniq.freeze
    @include_excluded = include_excluded
    @active_until_dates = (active_until_dates || {}).compact
      .to_h { |account_id, date| [ account_id.to_s, date.to_date ] }
      .slice(*@scope_account_ids)
      .freeze
  end

  # One of CLASSES, or nil when the entry carries no flow: excluded entries
  # (unless include_excluded), pending transactions, valuations.
  def classify(entry)
    return nil if entry.excluded? && !include_excluded

    case entry.entryable
    when Trade then classify_trade(entry, entry.entryable)
    when Transaction then classify_transaction(entry, entry.entryable)
    end
  end

  # The same decision as #classify for every id given, taken in SQL. Returns
  # { entry_id => class or nil }. Later drops embed #sql_case in their own
  # daily queries; this method is the reference the parity test holds them to.
  # The ids are not filtered by family; the caller passes ids it has scoped.
  def classify_ids(entry_ids)
    ids = Array(entry_ids).map(&:to_s)
    return {} if ids.empty?

    # The ids are bound by ActiveRecord rather than written into the string.
    # Building the whole statement and passing it back through
    # sanitize_sql_array would make Rails read any `:word` inside a label or
    # a literal as a bind variable it cannot find, and raise before the query
    # ever ran; #sql_case is already sanitized, and Arel.sql says so.
    Entry
      .where(id: ids)
      .joins(sql_joins)
      .pluck(Arel.sql("entries.id"), Arel.sql(sql_case))
      .to_h { |id, flow_class| [ id, flow_class&.to_sym ] }
  end

  # The joins #sql_case relies on. The caller's query must select FROM
  # `entries` and place this fragment before its WHERE clause.
  #
  # One row per entry, which an aggregate embedding this relies on, by
  # construction rather than by trust. Transfer validates each leg as unique,
  # but the only unique index is on the pair, so a writer that bypasses
  # validations (insert_all), or two matchers racing past the validation, can
  # make one transaction a leg of two transfers. A plain join would then give
  # the entry two rows and a SUM over it would count the entry twice. The
  # lateral reads one transfer per transaction, preferring one the
  # transaction is the inflow of, as #transfer_counterpart_account_id does,
  # then the earliest by created_at and id, which #classify reads too.
  def sql_joins
    <<~SQL.squish
      LEFT JOIN trades ON entries.entryable_type = 'Trade' AND trades.id = entries.entryable_id
      LEFT JOIN transactions ON entries.entryable_type = 'Transaction' AND transactions.id = entries.entryable_id
      LEFT JOIN LATERAL (
        SELECT t.inflow_transaction_id, t.outflow_transaction_id
        FROM transfers t
        WHERE entries.entryable_type = 'Transaction'
          AND (t.inflow_transaction_id = transactions.id OR t.outflow_transaction_id = transactions.id)
        ORDER BY (t.inflow_transaction_id = transactions.id) DESC, t.created_at, t.id
        LIMIT 1
      ) flow_transfers ON TRUE
      LEFT JOIN entries flow_counterpart_entries
        ON flow_counterpart_entries.entryable_type = 'Transaction'
        AND flow_counterpart_entries.entryable_id = CASE
          WHEN flow_transfers.inflow_transaction_id = transactions.id THEN flow_transfers.outflow_transaction_id
          ELSE flow_transfers.inflow_transaction_id
        END
    SQL
  end

  # A CASE expression yielding the class name as text, or NULL, for the row
  # `entries` / `trades` / `transactions` joined by #sql_joins. Every literal
  # in it comes from the constants above; the scope ids are the only bound
  # value.
  def sql_case
    <<~SQL.squish
      CASE
        #{"WHEN entries.excluded THEN NULL" unless include_excluded}
        WHEN entries.entryable_type NOT IN ('Trade', 'Transaction') THEN NULL
        WHEN entries.entryable_type = 'Transaction' AND (#{pending_sql}) THEN NULL
        WHEN transactions.transfer_id IS NOT NULL AND transactions.kind = 'standard' THEN 'fee'
        WHEN #{label_sql} IN (#{quote_list(INCOME_LABELS)}) THEN 'income'
        WHEN #{label_sql} IN (#{quote_list(FEE_LABELS)}) THEN 'fee'
        WHEN #{label_sql} IN (#{quote_list(INTERNAL_LABELS)}) THEN 'internal'
        WHEN #{label_sql} IN (#{quote_list(EXTERNAL_LABELS)}) THEN #{transfer_resolution_sql}
        WHEN #{label_sql} = '#{TRANSFER_LABEL}' AND entries.entryable_type = 'Trade'
          THEN CASE WHEN #{security_transfer_counterpart_in_scope_sql} THEN 'internal' ELSE #{direction_sql} END
        WHEN #{label_sql} = '#{TRANSFER_LABEL}' THEN #{transfer_resolution_sql}
        WHEN entries.entryable_type = 'Trade' THEN 'internal'
        WHEN transactions.kind IN (#{quote_list(Transaction::TRANSFER_KINDS)}) THEN #{transfer_resolution_sql}
        ELSE #{direction_sql}
      END
    SQL
  end

  private
    def classify_trade(entry, trade)
      rule = LABEL_RULES[trade.investment_activity_label]

      case rule
      when nil then :internal
      when :external then trade_direction(trade)
      when :transfer then security_transfer_counterpart_in_scope?(entry, trade) ? :internal : trade_direction(trade)
      else rule
      end
    end

    def classify_transaction(entry, transaction)
      return nil if transaction.pending?
      # The fee legs of a Transfer are plain standard transactions that point
      # back at their transfer; nothing else sets transfer_id.
      return :fee if transaction.transfer_id.present? && transaction.kind == "standard"

      rule = LABEL_RULES[transaction.investment_activity_label]

      case rule
      when nil
        transaction.transfer? ? transfer_resolution(entry, transaction) : transaction_direction(entry)
      # A Contribution or Withdrawal label says where the borrower thinks the
      # money went; a linked Transfer says where it actually went. When both
      # legs are inside the scope the movement is internal whatever either leg
      # is labelled, so the label cannot outrank the link. #transfer_resolution
      # falls back to the same direction this used to return whenever there is
      # no link, or the counterpart sits outside the scope.
      when :external then transfer_resolution(entry, transaction)
      when :transfer then transfer_resolution(entry, transaction)
      else rule
      end
    end

    def trade_direction(trade)
      trade.qty.negative? ? :external_outflow : :external_inflow
    end

    def transaction_direction(entry)
      entry.amount.negative? ? :external_inflow : :external_outflow
    end

    # Scope is checked on the COUNTERPART leg's date. A linked transfer's legs
    # can be days apart, and a series windowed by cut-off keeps or drops each
    # leg by its own date: a counterpart landing after its account's cut-off
    # is dropped, so this leg must be the external flow, and one sent before
    # it is kept, so this leg is internal even if dated after the cut-off.
    def transfer_resolution(entry, transaction)
      counterpart_account_id, counterpart_date = transfer_counterpart(transaction)
      if counterpart_account_id && in_scope_on?(counterpart_account_id, counterpart_date)
        :internal
      else
        transaction_direction(entry)
      end
    end

    # The account (by id only) and date of the other leg of a linked
    # Transfer; the counterpart account itself is never loaded, so a scope
    # check cannot leak an account the user is not allowed to see.
    #
    # The transfer is chosen as #sql_joins chooses it: one the transaction is
    # the inflow of first, then the earliest by created_at and id. Not through
    # transfer_as_inflow / transfer_as_outflow: has_one is unordered, so of two
    # transfers on one leg it can return either.
    def transfer_counterpart(transaction)
      transfer = earliest_transfer(inflow_transaction_id: transaction.id) ||
        earliest_transfer(outflow_transaction_id: transaction.id)
      return nil unless transfer

      counterpart_id = transfer.inflow_transaction_id == transaction.id ? transfer.outflow_transaction_id : transfer.inflow_transaction_id
      account_id, date = Entry.where(entryable_type: "Transaction", entryable_id: counterpart_id).pick(:account_id, :date)
      [ account_id&.to_s, date ]
    end

    def earliest_transfer(leg)
      Transfer.where(leg).order(:created_at, :id).first
    end

    # A security moved between accounts has no Transfer row; its other leg is
    # the opposite-quantity Transfer trade on the same security and date in
    # another account. An excluded leg does not count unless include_excluded
    # says to read it as live. entries.excluded is nullable, and a NULL leg is
    # live here as it is to #classify, hence IS NOT TRUE rather than = false.
    def security_transfer_counterpart_in_scope?(entry, trade)
      counterparts = Entry
        .joins("JOIN trades counterpart_trades ON counterpart_trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
        .where(account_id: scope_account_ids.select { |account_id| in_scope_on?(account_id, entry.date) })
        .where.not(account_id: entry.account_id)
        .where(date: entry.date)
        .where(counterpart_trades: { security_id: trade.security_id, qty: -trade.qty, investment_activity_label: TRANSFER_LABEL })
      counterparts = counterparts.where("entries.excluded IS NOT TRUE") unless include_excluded
      counterparts.exists?
    end

    # Inside the scope on `date`: one of its accounts, and not past its cut-off.
    def in_scope_on?(account_id, date)
      return false unless scope_account_ids.include?(account_id)

      active_until = active_until_dates[account_id]
      active_until.nil? || date <= active_until
    end

    def label_sql
      "COALESCE(trades.investment_activity_label, transactions.investment_activity_label)"
    end

    # A Trade's direction is its quantity's sign, and a summing caller takes
    # the magnitude from -entries.amount. Those agree for every writer today:
    # a Contribution or Withdrawal is written as a Transaction, and a
    # Transfer-labelled Trade as a journal or a cash amount signed like its
    # quantity. A Contribution Trade written as amount = qty x price would be
    # classed an inflow and summed as an outflow; nothing writes that shape.
    def direction_sql
      <<~SQL.squish
        CASE
          WHEN entries.entryable_type = 'Trade' THEN CASE WHEN trades.qty < 0 THEN 'external_outflow' ELSE 'external_inflow' END
          WHEN entries.amount < 0 THEN 'external_inflow'
          ELSE 'external_outflow'
        END
      SQL
    end

    def transfer_resolution_sql
      "CASE WHEN #{in_scope_sql('flow_counterpart_entries.account_id', 'flow_counterpart_entries.date')} THEN 'internal' ELSE #{direction_sql} END"
    end

    def security_transfer_counterpart_in_scope_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM entries counterpart_entries
          JOIN trades counterpart_trades
            ON counterpart_trades.id = counterpart_entries.entryable_id
            AND counterpart_entries.entryable_type = 'Trade'
          WHERE #{in_scope_sql('counterpart_entries.account_id')}
            AND counterpart_entries.account_id <> entries.account_id
            AND counterpart_entries.date = entries.date
            #{"AND counterpart_entries.excluded IS NOT TRUE" unless include_excluded}
            AND counterpart_trades.security_id = trades.security_id
            AND counterpart_trades.qty = -trades.qty
            AND counterpart_trades.investment_activity_label = '#{TRANSFER_LABEL}'
        )
      SQL
    end

    def pending_sql
      self.class.pending_sql
    end

    # #in_scope_on? as SQL: the account on the date given, the classified
    # entry's own unless a counterpart leg's is passed (see
    # #transfer_resolution). With no cut-offs it is the plain membership test. The cut-offs are written in
    # as quoted literals, like the scope ids: a uuid and an ISO date, neither
    # of which can spell a bind.
    def in_scope_sql(account_expression, date_expression = "entries.date")
      membership = "#{account_expression} = ANY(#{scope_ids_sql})"
      return membership if active_until_dates.empty?

      cut_offs = active_until_dates.map do |account_id, date|
        "(#{quote(account_id)}::uuid, #{quote(date.iso8601)}::date)"
      end.join(", ")

      <<~SQL.squish
        (#{membership} AND NOT EXISTS (
          SELECT 1 FROM (VALUES #{cut_offs}) AS flow_cut_offs(account_id, active_until_date)
          WHERE flow_cut_offs.account_id = #{account_expression}
            AND #{date_expression} > flow_cut_offs.active_until_date
        ))
      SQL
    end

    def quote(value)
      ActiveRecord::Base.connection.quote(value)
    end

    # The one bound value in the whole expression, sanitized on its own and
    # then written into the CASE as a literal.
    #
    # The alternative -- handing the finished CASE to sanitize_sql_array with
    # a named bind -- makes Rails scan a string that already contains every
    # label literal for `:name` placeholders, so the day a label carries a
    # colon ("Fee:Broker") it raises PreparedStatementInvalid before the
    # query runs, taking out whatever the CASE was embedded in.
    def scope_ids_sql
      @scope_ids_sql ||= ActiveRecord::Base.sanitize_sql_array(
        [ "ARRAY[:scope_account_ids]::uuid[]", { scope_account_ids: scope_account_ids } ]
      )
    end

    def quote_list(values)
      values.map { |value| quote(value) }.join(", ")
    end
end
