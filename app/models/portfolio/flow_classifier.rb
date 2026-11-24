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
# pending; a transfer-fee leg; the activity label on the Trade or Transaction
# (a split child without one reads its parent's); for an unlabelled
# Transaction its `kind`; and for a transfer, whether the counterpart leg's
# account is inside the scope on the entry's date. Direction for an external
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
#   scope is.
class Portfolio::FlowClassifier
  CLASSES = %i[external_inflow external_outflow income fee internal].freeze

  # Activity label -> class. Two pseudo-classes resolve at classification
  # time, and both consult the link before the label: :external and :transfer
  # each become :internal when the entry is a linked Transfer whose other leg
  # is inside the scope, and an inflow or an outflow by direction otherwise.
  # A label describes what the borrower meant; a Transfer row records where
  # the money went, and between two accounts in scope it went nowhere. A nil
  # rule means the label decides nothing and
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

  attr_reader :scope_account_ids, :include_excluded, :active_until_dates, :strict_leg_pairing

  # include_excluded: classify an excluded entry as if it were not excluded.
  # Excluding hides an entry from budgets and reports, but the balance
  # calculators still apply it (Balance::SyncCache), so a reader reconciling
  # against balances -- Portfolio::DailyReturns -- has to see it as the flow it
  # was. Split parents are excluded too and are NOT applied; that reader skips
  # them itself.
  #
  # active_until_dates: { account_id => last date in scope }. An account with
  # no entry is in scope on every date.
  #
  # strict_leg_pairing: pair two legs as one internal move only when they
  # moved the same balances on the same day, for a reader that values flows
  # day by day against those balances (Portfolio::DailyReturns). A linked
  # transfer is internal only when both legs post the same day. A security
  # journal is internal only when exactly one journal leg on the other side,
  # in another account, explains it and no other leg sits on its own side; a
  # same-account leg on the other side makes the day ambiguous. A
  # Transfer-labelled trade with a cash amount is a purchase or a sale
  # (#cash_settled?), so it is internal and is never a journal's other leg.
  # Off by default: a period total such as InvestmentStatement::Totals reads
  # a transfer as one move whichever days its legs post on.
  def initialize(scope_account_ids:, include_excluded: false, active_until_dates: {}, strict_leg_pairing: false)
    @scope_account_ids = Array(scope_account_ids).map(&:to_s).uniq.freeze
    @include_excluded = include_excluded
    @strict_leg_pairing = strict_leg_pairing
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
  # One row per entry, which an aggregate embedding this relies on.
  # Transfer#transfer_has_opposite_amounts makes a leg a transfer's inflow
  # while its amount is negative and its outflow while it is positive, and
  # Transfer validates each side as unique, so a transaction normally has one
  # transfer. Those checks run only when a transfer is saved. A leg's amount
  # can change sign afterwards (a provider re-sync writes it again), and such
  # a leg can then become another transfer's leg on the other side. One join
  # on either side would return both transfers, and a SUM would count the
  # entry twice.
  #
  # So the transfers are joined twice, once per side, and the sign chooses
  # between them without excluding either: flow_sign_transfers is the
  # transfer on the side the amount allows (the outflow while it is
  # positive, else the inflow), flow_other_transfers the one on the other
  # side, joined only when there is no flow_sign_transfers row, and
  # flow_transfers takes whichever was found. A leg whose sign
  # flipped on its own transfer, with no second transfer, keeps that link, as
  # do both legs of a pair whose amounts were negated together.
  # #confirmed_transfer_for picks the same transfer in Ruby.
  #
  # Two transfers on one side are possible too: the uniqueness validations
  # rule them out only for writers that run them one at a time, and two
  # racing writers, or rows written around the validations (insert_all), can
  # create them, since the table has a unique index on the pair only. Each
  # side's join then takes the earliest confirmed transfer, by created_at and
  # id, through a NOT EXISTS on an earlier one, so the entry still has one
  # row.
  #
  # Each join keeps the OR probe on both transfer columns, which uses the
  # index on each, and checks the side on top of it. Choosing the transfer
  # in a LATERAL ... ORDER BY ... LIMIT 1 instead gave one row in every case
  # but took the query out of its parallel plan and priced it past the JIT
  # inlining threshold; over five years it ran three to four times slower.
  #
  # The counterpart entry is only looked up among the scope's accounts, which
  # is all #transfer_resolution_sql asks of it: entries has no index on
  # entryable_id, and without the account bound the join reads every
  # Transaction entry in the database. InvestmentStatement::Totals#recorded_flow_sql
  # relies on this bound as well: there, a NULL counterpart means the other
  # leg is outside the scope.
  #
  # The security-transfer legs are joined grouped, one row per date,
  # security and quantity, so that join cannot fan out either (see
  # #security_transfer_legs_sql).
  #
  # A split child is joined to its parent transaction, whose label it reads
  # when it has none of its own (#split_parent_label).
  #
  # Only a confirmed Transfer links two legs. An auto-match starts out
  # pending and, as Transfer#confirm! promises, an unconfirmed suggestion
  # never moves a report, so until the user confirms it each leg is
  # classified as if it were unlinked.
  def sql_joins
    <<~SQL.squish
      LEFT JOIN trades ON entries.entryable_type = 'Trade' AND trades.id = entries.entryable_id
      LEFT JOIN transactions ON entries.entryable_type = 'Transaction' AND transactions.id = entries.entryable_id
      LEFT JOIN transfers flow_sign_transfers
        ON entries.entryable_type = 'Transaction'
        AND flow_sign_transfers.status = 'confirmed'
        AND (flow_sign_transfers.inflow_transaction_id = transactions.id OR flow_sign_transfers.outflow_transaction_id = transactions.id)
        AND CASE WHEN entries.amount > 0 THEN flow_sign_transfers.outflow_transaction_id ELSE flow_sign_transfers.inflow_transaction_id END = transactions.id
        AND NOT EXISTS (
          SELECT 1 FROM transfers flow_earlier_sign_transfers
          WHERE flow_earlier_sign_transfers.status = 'confirmed'
            AND ((entries.amount > 0 AND flow_earlier_sign_transfers.outflow_transaction_id = transactions.id)
              OR (NOT (entries.amount > 0) AND flow_earlier_sign_transfers.inflow_transaction_id = transactions.id))
            AND (flow_earlier_sign_transfers.created_at, flow_earlier_sign_transfers.id) < (flow_sign_transfers.created_at, flow_sign_transfers.id)
        )
      LEFT JOIN transfers flow_other_transfers
        ON entries.entryable_type = 'Transaction'
        AND flow_sign_transfers.id IS NULL
        AND flow_other_transfers.status = 'confirmed'
        AND (flow_other_transfers.inflow_transaction_id = transactions.id OR flow_other_transfers.outflow_transaction_id = transactions.id)
        AND CASE WHEN entries.amount > 0 THEN flow_other_transfers.inflow_transaction_id ELSE flow_other_transfers.outflow_transaction_id END = transactions.id
        AND NOT EXISTS (
          SELECT 1 FROM transfers flow_earlier_other_transfers
          WHERE flow_earlier_other_transfers.status = 'confirmed'
            AND ((entries.amount <= 0 AND flow_earlier_other_transfers.outflow_transaction_id = transactions.id)
              OR (NOT (entries.amount <= 0) AND flow_earlier_other_transfers.inflow_transaction_id = transactions.id))
            AND (flow_earlier_other_transfers.created_at, flow_earlier_other_transfers.id) < (flow_other_transfers.created_at, flow_other_transfers.id)
        )
      CROSS JOIN LATERAL (
        SELECT
          COALESCE(flow_sign_transfers.inflow_transaction_id, flow_other_transfers.inflow_transaction_id) AS inflow_transaction_id,
          COALESCE(flow_sign_transfers.outflow_transaction_id, flow_other_transfers.outflow_transaction_id) AS outflow_transaction_id
      ) flow_transfers
      LEFT JOIN entries flow_parent_entries
        ON flow_parent_entries.id = entries.parent_entry_id AND flow_parent_entries.entryable_type = 'Transaction'
      LEFT JOIN transactions flow_parent_transactions ON flow_parent_transactions.id = flow_parent_entries.entryable_id
      LEFT JOIN entries flow_counterpart_entries
        ON flow_counterpart_entries.entryable_type = 'Transaction'
        AND flow_counterpart_entries.account_id = ANY(#{scope_ids_sql})
        AND flow_counterpart_entries.entryable_id = CASE
          WHEN flow_transfers.inflow_transaction_id = transactions.id THEN flow_transfers.outflow_transaction_id
          ELSE flow_transfers.inflow_transaction_id
        END
      #{security_transfers_join_sql}
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
        WHEN entries.entryable_type = 'Trade' AND #{label_sql} IN (#{quote_list(cash_settled_labels)})
          AND trades.qty * entries.amount > 0 THEN 'internal'
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
      when :external then cash_settled?(entry, trade) ? :internal : trade_direction(trade)
      when :transfer
        (strict_leg_pairing && cash_settled?(entry, trade)) || security_transfer_counterpart_in_scope?(entry, trade) ? :internal : trade_direction(trade)
      else rule
      end
    end

    def classify_transaction(entry, transaction)
      return nil if transaction.pending?
      # The fee legs of a Transfer are plain standard transactions that point
      # back at their transfer; nothing else sets transfer_id.
      return :fee if transaction.transfer_id.present? && transaction.kind == "standard"

      rule = LABEL_RULES[transaction.investment_activity_label || split_parent_label(entry)]

      case rule
      when nil
        transaction.transfer? ? transfer_resolution(entry, transaction) : transaction_direction(entry)
      # A Contribution or Withdrawal label says where the borrower thinks the
      # money went; a linked Transfer says where it actually went. When both
      # legs are inside the scope the movement is internal whatever either leg
      # is labelled, so the label cannot outrank the link. #transfer_resolution
      # falls back to the direction whenever there is no link, or the
      # counterpart sits outside the scope.
      when :external then transfer_resolution(entry, transaction)
      when :transfer then transfer_resolution(entry, transaction)
      else rule
      end
    end

    # A Contribution or Withdrawal trade (and, under strict_leg_pairing, a
    # Transfer trade) whose amount is signed like its quantity (qty x price, as the trades form and API write it). The
    # balance calculators apply it as a buy or a sale, cash for units at the
    # same value, so nothing crosses the scope. In kind (amount 0, a security
    # journal) or cash only (qty 0), it is an external flow by direction.
    def cash_settled?(entry, trade)
      (trade.qty * entry.amount).positive?
    end

    def cash_settled_labels
      strict_leg_pairing ? EXTERNAL_LABELS + [ TRANSFER_LABEL ] : EXTERNAL_LABELS
    end

    def trade_direction(trade)
      trade.qty.negative? ? :external_outflow : :external_inflow
    end

    def transaction_direction(entry)
      entry.amount.negative? ? :external_inflow : :external_outflow
    end

    # Internal only when the other leg's account is in scope on this entry's
    # date: one of the scope's accounts, and not past its cut-off. Under
    # strict_leg_pairing the other leg must also post that day: each leg moves
    # its own balance on its own date, so across days each is a flow on its
    # day.
    def transfer_resolution(entry, transaction)
      counterpart_account_id, counterpart_date = transfer_counterpart(entry, transaction)
      if counterpart_account_id && in_scope_on?(counterpart_account_id, entry.date) &&
          (!strict_leg_pairing || counterpart_date == entry.date)
        :internal
      else
        transaction_direction(entry)
      end
    end

    # The account (by id only) and date of the other leg of a confirmed
    # Transfer; the counterpart account itself is never loaded, so a scope
    # check cannot leak an account the user is not allowed to see. A pending
    # auto-match links nothing yet.
    def transfer_counterpart(entry, transaction)
      transfer = confirmed_transfer_for(entry, transaction)
      return nil unless transfer

      counterpart_id = transfer.inflow_transaction_id == transaction.id ? transfer.outflow_transaction_id : transfer.inflow_transaction_id
      account_id, date = Entry.where(entryable_type: "Transaction", entryable_id: counterpart_id).pick(:account_id, :date)
      [ account_id&.to_s, date ]
    end

    # The transfer #sql_joins picks for this transaction: the confirmed one
    # on the side its sign allows (the outflow while its amount is positive,
    # else the inflow), else the confirmed one on the other side; of two on
    # one side, the earliest by created_at and id.
    def confirmed_transfer_for(entry, transaction)
      sides = %i[inflow_transaction_id outflow_transaction_id]
      sides.reverse! if entry.amount.positive?
      sides.lazy.map { |side| Transfer.confirmed.where(side => transaction.id).order(:created_at, :id).first }.find(&:itself)
    end

    # A security moved between accounts has no Transfer row; its other leg is
    # the opposite-quantity Transfer trade on the same security and date, in
    # another account inside the scope on that date. An excluded leg does not
    # count unless include_excluded says to read it as live. entries.excluded
    # is nullable, and a NULL leg is live here as it is to #classify, hence
    # IS NOT TRUE rather than = false.
    #
    # Under strict_leg_pairing only journal legs count (a cash-settled one is
    # a purchase or a sale), and the pairing has to be one to one: exactly one
    # opposite journal leg in any account, in another account than this one,
    # and no other journal leg on this leg's side. With more legs than one
    # move explains, every leg is a flow by direction.
    def security_transfer_counterpart_in_scope?(entry, trade)
      return strictly_paired_security_transfer?(entry, trade) if strict_leg_pairing

      security_transfer_legs(entry, trade.security_id, -trade.qty).where.not(account_id: entry.account_id).exists?
    end

    def strictly_paired_security_transfer?(entry, trade)
      opposite_accounts = security_transfer_legs(entry, trade.security_id, -trade.qty).where.not(id: entry.id).limit(2).pluck(:account_id)
      same_side = security_transfer_legs(entry, trade.security_id, trade.qty).where.not(id: entry.id)
      opposite_accounts.size == 1 && opposite_accounts.first != entry.account_id && !same_side.exists?
    end

    def security_transfer_legs(entry, security_id, qty)
      legs = Entry
        .joins("JOIN trades counterpart_trades ON counterpart_trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
        .where(account_id: scope_account_ids.select { |account_id| in_scope_on?(account_id, entry.date) })
        .where(date: entry.date)
        .where(counterpart_trades: { security_id: security_id, qty: qty, investment_activity_label: TRANSFER_LABEL })
      legs = legs.where("counterpart_trades.qty * entries.amount <= 0") if strict_leg_pairing
      include_excluded ? legs : legs.where("entries.excluded IS NOT TRUE")
    end

    # Inside the scope on `date`: one of its accounts, and not past its cut-off.
    def in_scope_on?(account_id, date)
      return false unless scope_account_ids.include?(account_id)

      active_until = active_until_dates[account_id]
      active_until.nil? || date <= active_until
    end

    # Entry#split! copies a parent's kind to its children but not its
    # activity label, and readers skip the parent, so a child with no label
    # of its own reads its parent's: a split dividend is still a dividend.
    def split_parent_label(entry)
      parent = entry.parent_entry&.entryable
      parent.investment_activity_label if parent.is_a?(Transaction)
    end

    def label_sql
      "COALESCE(trades.investment_activity_label, transactions.investment_activity_label, flow_parent_transactions.investment_activity_label)"
    end

    # A Trade's direction is its quantity's sign, and a summing caller takes
    # the magnitude from -entries.amount. For a Contribution or Withdrawal
    # trade the two would disagree when the amount is signed like the
    # quantity, which the trades form and API write; that shape is internal
    # (#cash_settled?) and never reaches here.
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
      same_day = "flow_counterpart_entries.date = entries.date AND " if strict_leg_pairing
      "CASE WHEN #{same_day}#{in_scope_sql('flow_counterpart_entries.account_id')} THEN 'internal' ELSE #{direction_sql} END"
    end

    # True when #security_transfer_legs_sql found a Transfer trade on the
    # same date and security, with the opposite quantity, in a scope account
    # other than this entry's. Each group carries the lowest and highest
    # account id among its legs, so a leg in another account exists exactly
    # when either differs from this entry's. With no group, both are NULL and
    # the CASE takes the direction.
    #
    # Under strict_leg_pairing, the SQL twin of
    # #strictly_paired_security_transfer?: the other side holds exactly one
    # journal leg, in another account, and this entry's own side holds none
    # but the entry itself, which it holds when the entry is in scope on its
    # date (a journal leg reaching here is never cash-settled).
    def security_transfer_counterpart_in_scope_sql
      if strict_leg_pairing
        <<~SQL.squish
          (#{security_transfer_side_sql('legs', opposite: true)} = 1
            AND #{security_transfer_side_sql('account_id', opposite: true)} <> entries.account_id
            AND COALESCE(#{security_transfer_side_sql('legs', opposite: false)}, 0) <= CASE WHEN #{in_scope_sql('entries.account_id')} THEN 1 ELSE 0 END)
        SQL
      else
        <<~SQL.squish
          (flow_security_transfers.min_account_id <> entries.account_id
            OR flow_security_transfers.max_account_id <> entries.account_id)
        SQL
      end
    end

    # Strict pairing reads both sides of a security's day, so its one grouped
    # join is keyed on the quantity's magnitude and carries each side apart:
    # legs in (qty > 0), out (qty < 0) and, for a qty 0 leg, whose other side
    # is itself, zero.
    def security_transfers_join_sql
      if strict_leg_pairing
        <<~SQL.squish
          LEFT JOIN (#{strict_security_transfer_legs_sql}) flow_security_transfers
            ON entries.entryable_type = 'Trade'
            AND flow_security_transfers.date = entries.date
            AND flow_security_transfers.security_id = trades.security_id
            AND flow_security_transfers.abs_qty = ABS(trades.qty)
        SQL
      else
        <<~SQL.squish
          LEFT JOIN (#{security_transfer_legs_sql}) flow_security_transfers
            ON entries.entryable_type = 'Trade'
            AND flow_security_transfers.date = entries.date
            AND flow_security_transfers.security_id = trades.security_id
            AND flow_security_transfers.qty = -trades.qty
        SQL
      end
    end

    # One column of the strict group, from the entry's own side or the other.
    def security_transfer_side_sql(column, opposite:)
      positive, negative = opposite ? %w[out in] : %w[in out]
      "CASE WHEN trades.qty > 0 THEN flow_security_transfers.#{positive}_#{column} " \
        "WHEN trades.qty < 0 THEN flow_security_transfers.#{negative}_#{column} " \
        "ELSE flow_security_transfers.zero_#{column} END"
    end

    # Every live Transfer trade in the scope's accounts, grouped by date,
    # security and quantity. A correlated EXISTS asked the same question per
    # row, and the planner priced each probe against the whole scope, so its
    # estimate grew with the square of the entries and a few thousand crossed
    # jit_above_cost; JIT compilation then took longer than the query.
    # Grouped and hash-joined, the cost stays proportional to the rows read.
    #
    # A leg counts only inside the scope on its own date, and an excluded one
    # only under include_excluded. entries.excluded is nullable, and a NULL
    # leg is live here as it is to #classify, hence IS NOT TRUE rather than
    # = false. uuid has no MIN or MAX, so the ids are compared as text.
    def security_transfer_legs_sql
      <<~SQL.squish
        SELECT
          counterpart_entries.date,
          counterpart_trades.security_id,
          counterpart_trades.qty,
          MIN(counterpart_entries.account_id::text)::uuid AS min_account_id,
          MAX(counterpart_entries.account_id::text)::uuid AS max_account_id
        #{security_transfer_legs_from_sql}
        GROUP BY counterpart_entries.date, counterpart_trades.security_id, counterpart_trades.qty
      SQL
    end

    # The strict form of the same groups: journal legs only (a cash-settled
    # one is a purchase or a sale), keyed on the quantity's magnitude, with
    # each side's leg count and, for a side of one leg, that leg's account.
    def strict_security_transfer_legs_sql
      sides = { "in" => "> 0", "out" => "< 0", "zero" => "= 0" }.map do |side, test|
        "COUNT(*) FILTER (WHERE counterpart_trades.qty #{test}) AS #{side}_legs, " \
          "MIN(counterpart_entries.account_id::text) FILTER (WHERE counterpart_trades.qty #{test})::uuid AS #{side}_account_id"
      end

      <<~SQL.squish
        SELECT
          counterpart_entries.date,
          counterpart_trades.security_id,
          ABS(counterpart_trades.qty) AS abs_qty,
          #{sides.join(", ")}
        #{security_transfer_legs_from_sql}
          AND counterpart_trades.qty * counterpart_entries.amount <= 0
        GROUP BY counterpart_entries.date, counterpart_trades.security_id, ABS(counterpart_trades.qty)
      SQL
    end

    def security_transfer_legs_from_sql
      <<~SQL.squish
        FROM entries counterpart_entries
        JOIN trades counterpart_trades
          ON counterpart_trades.id = counterpart_entries.entryable_id
          AND counterpart_entries.entryable_type = 'Trade'
        WHERE #{in_scope_sql('counterpart_entries.account_id', date_expression: 'counterpart_entries.date')}
          #{"AND counterpart_entries.excluded IS NOT TRUE" unless include_excluded}
          AND counterpart_trades.investment_activity_label = '#{TRANSFER_LABEL}'
      SQL
    end

    def pending_sql
      self.class.pending_sql
    end

    # #in_scope_on? as SQL, on the date of the entry the CASE is classifying
    # unless date_expression names another. With no cut-offs it is the plain
    # membership test. The cut-offs are written in as quoted literals, like
    # the scope ids: a uuid and an ISO date, neither of which can spell a bind.
    def in_scope_sql(account_expression, date_expression: "entries.date")
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
