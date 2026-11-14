class InvestmentStatement::Totals
  def initialize(family, account_ids:, date_range:)
    @family = family
    @account_ids = account_ids
    @date_range = date_range
  end

  def call
    return empty_result if @account_ids.empty?

    result = select_without_jit(query_sql)

    {
      contributions: result["contributions"]&.to_d || 0,
      withdrawals: result["withdrawals"]&.to_d || 0,
      buys: result["buys"]&.to_d || 0,
      sells: result["sells"]&.to_d || 0,
      dividends: result["dividends"]&.to_d || 0,
      interest: result["interest"]&.to_d || 0,
      trades_count: result["trades_count"]&.to_i || 0
    }
  end

  private
    # Portfolio::FlowClassifier's CASE carries a correlated EXISTS (the
    # security-transfer check) that the planner prices for every row, so a
    # few hundred entries already push the estimate past jit_above_cost, and
    # compiling the plan then takes far longer than running it: on five years
    # of synthetic data, about 750 ms of a 900 ms query. SET LOCAL ends with
    # the enclosing transaction, so no other statement is affected.
    def select_without_jit(sql)
      connection = ActiveRecord::Base.connection

      connection.transaction(requires_new: true) do
        connection.execute("SET LOCAL jit = off")
        connection.select_one(sql)
      end
    end

    def empty_result
      {
        contributions: 0,
        withdrawals: 0,
        buys: 0,
        sells: 0,
        dividends: 0,
        interest: 0,
        trades_count: 0
      }
    end

    # The bound values are sanitized on their own and the classifier's
    # fragments spliced in afterwards: #sql_case is already sanitized, and
    # running it through sanitize_sql_array again would read any `:word` in
    # a label literal as a bind (see Portfolio::FlowClassifier#scope_ids_sql).
    def query_sql
      aggregation_sql
        .sub("__FLOW_JOINS__") { flow_classifier.sql_joins }
        .gsub("__FLOW_CLASS__") { "(#{flow_classifier.sql_case})" }
        .gsub("__RECORDED_FLOW__") { recorded_flow_sql }
    end

    # Contributions and withdrawals are money that entered or left the
    # accounts in scope: deposits, withdrawals, and transfers or journalled
    # positions whose other leg is outside the scope. Portfolio::FlowClassifier
    # decides that, with the same account ids the card reads as its scope, so
    # a transfer between two of those accounts is internal and counts on
    # neither side. A buy or a sale is internal to the account: it turns cash
    # into a security or back, so it is not money added or taken out.
    #
    # The classifier picks the direction from the sign (a Transaction) or the
    # quantity (a Trade), so ABS of the amount in its class is the size of
    # the flow.
    #
    # The card counts a flow only when the row says it is one (see
    # #recorded_flow_sql), not by the sign the classifier falls back to for
    # any other cash row. Only those rows, income and trades are read, and
    # the lateral `flow` subquery classifies each of them once (OFFSET 0
    # keeps the planner from inlining the CASE into both sums).
    #
    # Buys (qty > 0) and sells (qty < 0) are still summed, as before, under
    # their own names: the cash committed to buying securities and the cash
    # a sale brought back.
    #
    # Investment income (dividends, interest) is aggregated by activity label
    # rather than by direction. Since #1311 these are recorded as Trades with
    # qty: 0 and price: 0 (Trade::CreateForm#create_income_trade).
    #
    # Several providers store the same income as a Transaction carrying the
    # same label instead (Trading212, IBKR, Questrade, SnapTrade, Indexa
    # Capital, Kraken's fiat staking and earn rows), so income reads the label
    # from whichever of the two the entry is. Pending transactions are left
    # out until they post, for income and flows alike. A Transaction has no
    # trades row, so it never reaches the buy and sell branches or
    # trades_count.
    #
    # Income is summed signed and then negated, as Portfolio::FlowClassifier
    # requires: a negative amount is money in, so a margin-interest charge or
    # a dividend reversal carrying an income label reduces the total instead
    # of adding to it.
    #
    # The buy and sell branches additionally exclude income labels rather than
    # relying on qty: 0 to keep the buckets disjoint. Without this guard such
    # a row would be counted twice: once by direction and once as income.
    #
    # A row in a currency with no rate at all is left out, not counted at 1,
    # as in InvestmentStatement; ExchangeRate.rate_sql gives the
    # nearest stored rate otherwise.
    #
    # account_ids is already scoped to the family's visible (draft/active)
    # investment accounts, so the query trusts that input and skips a join back
    # to accounts for family/status filtering.
    # COALESCE keeps an unlabeled trade (NULL) out of the set.
    def income_label_sql
      "COALESCE(trades.investment_activity_label, '') IN ('Dividend', 'Interest')"
    end

    def flow_classifier
      @flow_classifier ||= Portfolio::FlowClassifier.new(scope_account_ids: @account_ids)
    end

    # The rows that record a movement of money in or out: a Trade or a
    # Transaction labelled Contribution, Withdrawal or Transfer (the
    # classifier calls any other Trade internal), a Transaction of a transfer
    # kind, or a leg of a confirmed Transfer whose other leg is outside the
    # scope (flow_transfers and flow_counterpart_entries, joined by the
    # classifier). Transfer::Creator and Transfer#confirm! give both legs a
    # transfer kind; a link written another way (an import, an older row) can
    # leave them standard. Such a leg is still money in or out when its other
    # leg is outside the scope, and the classifier gives it its direction. With
    # the other leg in the scope it is not counted: the classifier resolves a
    # link only for a transfer kind or label and reads any other row by its
    # sign, so the move would count on both sides.
    #
    # Any other cash row is left out, even though the classifier gives it a
    # direction by its sign. Providers write investment activity that is not
    # a flow that way: SimpleFIN records buys and sales as unlabelled
    # Transactions, and Plaid labels its "cash" type, which covers dividends
    # and interest, "Other". Counting those by sign would bring back the
    # trades-as-contributions reading this card replaced. A manual deposit
    # counts once it is labelled Contribution.
    def recorded_flow_sql
      labels = (Portfolio::FlowClassifier::EXTERNAL_LABELS + [ Portfolio::FlowClassifier::TRANSFER_LABEL ])

      <<~SQL.squish
        (
          COALESCE(trades.investment_activity_label, transactions.investment_activity_label) IN (#{quote_list(labels)})
          OR transactions.kind IN (#{quote_list(Transaction::TRANSFER_KINDS)})
          OR (flow_transfers.inflow_transaction_id IS NOT NULL AND flow_counterpart_entries.account_id IS NULL)
        )
      SQL
    end

    def quote_list(values)
      values.map { |value| ActiveRecord::Base.connection.quote(value) }.join(", ")
    end

    def aggregation_sql
      rate = ExchangeRate.rate_sql(from: "entries.currency", to: ":target_currency", on: "entries.date")

      ActiveRecord::Base.sanitize_sql_array([ <<~SQL, sql_params ])
        SELECT
          COALESCE(SUM(CASE WHEN flow.flow_class = 'external_inflow' THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as contributions,
          COALESCE(SUM(CASE WHEN flow.flow_class = 'external_outflow' THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as withdrawals,
          COALESCE(SUM(CASE WHEN trades.qty > 0 AND NOT #{income_label_sql} THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as buys,
          COALESCE(SUM(CASE WHEN trades.qty < 0 AND NOT #{income_label_sql} THEN ABS(entries.amount * #{rate}) ELSE 0 END), 0) as sells,
          COALESCE(-SUM(CASE WHEN #{label_sql} = 'Dividend' THEN entries.amount * #{rate} ELSE 0 END), 0) as dividends,
          COALESCE(-SUM(CASE WHEN #{label_sql} = 'Interest' THEN entries.amount * #{rate} ELSE 0 END), 0) as interest,
          COUNT(trades.id) as trades_count
        FROM entries
        __FLOW_JOINS__
        LEFT JOIN LATERAL (
          SELECT __FLOW_CLASS__ AS flow_class
          WHERE __RECORDED_FLOW__
          OFFSET 0
        ) flow ON true
        WHERE entries.account_id IN (:account_ids)
          AND entries.date BETWEEN :start_date AND :end_date
          AND entries.excluded = false
          AND (
            entries.entryable_type = 'Trade'
            OR (
              entries.entryable_type = 'Transaction'
              AND (transactions.investment_activity_label IN ('Dividend', 'Interest') OR __RECORDED_FLOW__)
              #{Transaction.pending_providers_sql("transactions")}
            )
          )
      SQL
    end

    def label_sql
      "COALESCE(trades.investment_activity_label, transactions.investment_activity_label)"
    end

    def sql_params
      {
        target_currency: @family.currency,
        account_ids: @account_ids,
        start_date: @date_range.begin,
        end_date: @date_range.end
      }
    end
end
