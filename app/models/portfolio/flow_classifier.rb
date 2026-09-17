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
# they agree (docs/portfolio/methodology.md, contract rows P1-P16).
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
class Portfolio::FlowClassifier
  CLASSES = %i[external_inflow external_outflow income fee internal].freeze

  # Activity label -> class. Two pseudo-classes resolve at classification
  # time: :external becomes an inflow or an outflow by direction, and
  # :transfer becomes :internal when the counterpart is in scope and an
  # external flow otherwise. A nil rule means the label decides nothing and
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

  attr_reader :scope_account_ids

  def initialize(scope_account_ids:)
    @scope_account_ids = Array(scope_account_ids).map(&:to_s).uniq.freeze
  end

  # One of CLASSES, or nil when the entry carries no flow: excluded entries,
  # pending transactions, valuations.
  def classify(entry)
    return nil if entry.excluded?

    case entry.entryable
    when Trade then classify_trade(entry, entry.entryable)
    when Transaction then classify_transaction(entry, entry.entryable)
    end
  end

  # The same decision as #classify for every id given, taken in SQL. Returns
  # { entry_id => class or nil }. Later drops embed #sql_case in their own
  # daily queries; this method is the reference the parity test holds them to.
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
  # One row per entry, which an aggregate embedding this relies on: the
  # transfers join cannot fan out because Transfer validates
  # inflow_transaction_id and outflow_transaction_id as unique and requires
  # opposite amounts, so a transaction is a leg of at most one transfer. A
  # writer that bypasses validations (insert_all) could break that, and a SUM
  # over this join would then count the entry twice.
  def sql_joins
    <<~SQL.squish
      LEFT JOIN trades ON entries.entryable_type = 'Trade' AND trades.id = entries.entryable_id
      LEFT JOIN transactions ON entries.entryable_type = 'Transaction' AND transactions.id = entries.entryable_id
      LEFT JOIN transfers flow_transfers
        ON entries.entryable_type = 'Transaction'
        AND (flow_transfers.inflow_transaction_id = transactions.id OR flow_transfers.outflow_transaction_id = transactions.id)
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
        WHEN entries.excluded THEN NULL
        WHEN entries.entryable_type NOT IN ('Trade', 'Transaction') THEN NULL
        WHEN entries.entryable_type = 'Transaction' AND (#{pending_sql}) THEN NULL
        WHEN transactions.transfer_id IS NOT NULL AND transactions.kind = 'standard' THEN 'fee'
        WHEN #{label_sql} IN (#{quote_list(INCOME_LABELS)}) THEN 'income'
        WHEN #{label_sql} IN (#{quote_list(FEE_LABELS)}) THEN 'fee'
        WHEN #{label_sql} IN (#{quote_list(INTERNAL_LABELS)}) THEN 'internal'
        WHEN #{label_sql} IN (#{quote_list(EXTERNAL_LABELS)}) THEN #{direction_sql}
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
      when :external then transaction_direction(entry)
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

    def transfer_resolution(entry, transaction)
      counterpart_account_id = transfer_counterpart_account_id(transaction)
      if counterpart_account_id && scope_account_ids.include?(counterpart_account_id)
        :internal
      else
        transaction_direction(entry)
      end
    end

    # The account on the other leg of a linked Transfer, by id only; the
    # counterpart account itself is never loaded, so a scope check cannot
    # leak an account the user is not allowed to see.
    def transfer_counterpart_account_id(transaction)
      transfer = transaction.transfer_as_inflow || transaction.transfer_as_outflow
      return nil unless transfer

      counterpart_id = transfer.inflow_transaction_id == transaction.id ? transfer.outflow_transaction_id : transfer.inflow_transaction_id
      Entry.where(entryable_type: "Transaction", entryable_id: counterpart_id).pick(:account_id)&.to_s
    end

    # A security moved between accounts has no Transfer row; its other leg is
    # the opposite-quantity Transfer trade on the same security and date in
    # another account.
    def security_transfer_counterpart_in_scope?(entry, trade)
      Entry
        .joins("JOIN trades counterpart_trades ON counterpart_trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
        .where(account_id: scope_account_ids)
        .where.not(account_id: entry.account_id)
        .where(date: entry.date, excluded: false)
        .where(counterpart_trades: { security_id: trade.security_id, qty: -trade.qty, investment_activity_label: TRANSFER_LABEL })
        .exists?
    end

    def label_sql
      "COALESCE(trades.investment_activity_label, transactions.investment_activity_label)"
    end

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
      "CASE WHEN flow_counterpart_entries.account_id = ANY(#{scope_ids_sql}) THEN 'internal' ELSE #{direction_sql} END"
    end

    def security_transfer_counterpart_in_scope_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM entries counterpart_entries
          JOIN trades counterpart_trades
            ON counterpart_trades.id = counterpart_entries.entryable_id
            AND counterpart_entries.entryable_type = 'Trade'
          WHERE counterpart_entries.account_id = ANY(#{scope_ids_sql})
            AND counterpart_entries.account_id <> entries.account_id
            AND counterpart_entries.date = entries.date
            AND counterpart_entries.excluded = false
            AND counterpart_trades.security_id = trades.security_id
            AND counterpart_trades.qty = -trades.qty
            AND counterpart_trades.investment_activity_label = '#{TRANSFER_LABEL}'
        )
      SQL
    end

    def pending_sql
      self.class.pending_sql
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
      values.map { |value| ActiveRecord::Base.connection.quote(value) }.join(", ")
    end
end
