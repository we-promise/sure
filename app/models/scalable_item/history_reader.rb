require "bigdecimal"

class ScalableItem::HistoryReader
  PAGE_SIZE = 100
  MAX_PAGES = 100
  MAX_ROWS = 10_000
  MAX_REQUESTS = 1_000
  MAX_ID_BYTES = 256
  MAX_CURSOR_BYTES = 4_096
  MAX_STATUS_BYTES = 64
  MAX_DECIMAL_BYTES = 128

  Summary = Data.define(
    :row,
    :id,
    :identity,
    :status,
    :currency,
    :type,
    :cash_transaction_type,
    :amount,
    :last_event_date_time
  )

  def initialize(provider:, account_id:, portfolio_id:)
    @provider = provider
    @account_id = required_string(account_id, MAX_ID_BYTES)
    @portfolio_id = required_string(portfolio_id, MAX_ID_BYTES)
  end

  def read
    @requests = 0
    summaries = read_summary_pass
    details = summaries.map do |summary|
      detail = read_detail(summary)
      detail["summary_status"] = summary.status if summary.status
      detail
    end
    confirmation = read_summary_pass
    history_changed! unless summary_identity(summaries) == summary_identity(confirmation)

    details
  end

  private

    def read_summary_pass
      rows = []
      seen_ids = {}
      seen_cursors = {}
      cursor = nil
      expected_total = nil
      pages = 0

      loop do
        pages += 1
        history_incomplete! if pages > MAX_PAGES
        if cursor
          history_incomplete! if seen_cursors[cursor]
          seen_cursors[cursor] = true
        end

        data = perform_read(
          :broker_transactions,
          "accountId" => @account_id,
          "portfolioId" => @portfolio_id,
          "input" => {
            "pageSize" => PAGE_SIZE,
            "cursor" => cursor,
            "type" => nil,
            "status" => nil,
            "searchTerm" => nil,
            "fromTime" => nil,
            "toTime" => nil,
            "isin" => nil,
            "includeReinvestmentSubtypes" => true
          }
        )
        page = scoped_result(data, "moreTransactions")
        history_incomplete! unless page.key?("total") && page.key?("cursor") && page.key?("transactions")

        total = page["total"]
        history_incomplete! unless total.is_a?(Integer) && total >= 0 && total <= MAX_ROWS
        expected_total ||= total
        history_incomplete! unless total == expected_total

        page_rows = page["transactions"]
        history_incomplete! unless page_rows.is_a?(Array) && page_rows.length <= PAGE_SIZE

        page_rows.each do |row|
          summary = normalize_summary(row)
          history_incomplete! if seen_ids[summary.id]

          seen_ids[summary.id] = true
          rows << summary
          history_incomplete! if rows.length > MAX_ROWS || rows.length > expected_total
        end

        next_cursor = optional_cursor(page["cursor"])
        if rows.length == expected_total
          history_incomplete! if next_cursor
          break
        end

        history_incomplete! if page_rows.empty? || next_cursor.nil?
        history_incomplete! if seen_cursors[next_cursor]
        cursor = next_cursor
      end

      history_incomplete! unless rows.length == expected_total
      rows
    end

    def normalize_summary(raw)
      row = required_hash(raw)
      typename = required_string(row["__typename"], MAX_STATUS_BYTES)
      history_unsupported! unless typename == "BrokerCashTransactionSummary"

      id = required_string(row["id"], MAX_ID_BYTES)
      currency = required_currency(row["currency"])
      type = required_string(row["type"], MAX_STATUS_BYTES)
      history_unsupported! unless type == "CASH_TRANSACTION"

      status = optional_string(row["status"], MAX_STATUS_BYTES)
      is_cancellation = row["isCancellation"]
      history_incomplete! unless [ true, false ].include?(is_cancellation)
      cash_transaction_type = required_string(row["cashTransactionType"], MAX_STATUS_BYTES)
      amount = decimal(row["amount"])
      last_event_date_time = required_string(row["lastEventDateTime"], 128)

      identity = [
        typename,
        type,
        currency,
        status,
        is_cancellation,
        cash_transaction_type,
        amount.to_s("F"),
        last_event_date_time
      ].freeze

      Summary.new(
        row: { "isCancellation" => is_cancellation }.freeze,
        id: id,
        identity: identity,
        status: status,
        currency: currency,
        type: type,
        cash_transaction_type: cash_transaction_type,
        amount: amount,
        last_event_date_time: last_event_date_time
      )
    end

    def read_detail(summary)
      data = perform_read(
        :broker_transaction_details,
        "accountId" => @account_id,
        "portfolioId" => @portfolio_id,
        "transactionId" => summary.id
      )
      detail = scoped_result(data, "transactionDetails")

      detail_id = required_string(detail["id"], MAX_ID_BYTES)
      detail_type = required_string(detail["type"], MAX_STATUS_BYTES)
      detail_currency = required_currency(detail["currency"])
      detail_typename = required_string(detail["__typename"], MAX_STATUS_BYTES)
      history_changed! unless detail_id == summary.id && detail_type == summary.type && detail_currency == summary.currency
      history_changed! unless detail_typename == "BrokerCashTransaction"
      detail_is_cancellation = detail["isCancellation"]
      history_incomplete! unless [ true, false ].include?(detail_is_cancellation)
      history_changed! unless detail_is_cancellation == summary.row["isCancellation"]

      cash_transaction_type = required_string(detail["cashTransactionType"], MAX_STATUS_BYTES)
      amount = decimal(detail["amount"])
      last_event_date_time = required_string(detail["lastEventDateTime"], 128)
      history_changed! unless cash_transaction_type == summary.cash_transaction_type && amount == summary.amount
      history_changed! unless last_event_date_time == summary.last_event_date_time

      detail.deep_dup
    end

    def summary_identity(summaries)
      summaries.sort_by(&:id).map { |summary| [ summary.id, summary.identity ] }
    end

    def perform_read(operation, variables)
      @requests += 1
      history_incomplete! if @requests > MAX_REQUESTS
      @provider.read(operation, variables: variables)
    rescue Provider::Scalable::Error
      raise
    rescue StandardError
      history_incomplete!
    end

    def scoped_result(value, result_key)
      response = required_hash(value)
      account = required_hash(response["account"])
      account_id = required_string(account["id"], MAX_ID_BYTES)
      portfolio = required_hash(account["brokerPortfolio"])
      portfolio_id = required_string(portfolio["id"], MAX_ID_BYTES)
      history_changed! unless account_id == @account_id && portfolio_id == @portfolio_id

      required_hash(portfolio[result_key])
    end

    def required_hash(value)
      history_incomplete! unless value.is_a?(Hash)

      value
    end

    def required_string(value, max_bytes)
      history_incomplete! unless value.is_a?(String) && value.bytesize <= max_bytes && value.present? &&
        value == value.strip && !value.match?(/[\u0000-\u001F\u007F]/)

      value
    end

    def optional_string(value, max_bytes)
      return if value.nil? || value == ""

      required_string(value, max_bytes)
    end

    def required_currency(value)
      currency = required_string(value, 3)
      history_incomplete! unless currency.match?(/\A[A-Z]{3}\z/)

      currency
    end

    def optional_cursor(value)
      return if value.nil?

      required_string(value, MAX_CURSOR_BYTES)
    end

    def decimal(value)
      unless value.is_a?(String) || value.is_a?(Numeric)
        history_incomplete!
      end
      history_incomplete! if value.to_s.bytesize > MAX_DECIMAL_BYTES
      history_incomplete! if value.is_a?(Float) && !value.finite?

      result = BigDecimal(value.to_s)
      history_incomplete! unless result.finite?

      result
    rescue ArgumentError, TypeError
      history_incomplete!
    end

    def history_incomplete!
      raise Provider::Scalable::Error.new(:history_incomplete), cause: nil
    end

    def history_changed!
      raise Provider::Scalable::Error.new(:history_changed), cause: nil
    end

    def history_unsupported!
      raise Provider::Scalable::Error.new(:history_unsupported), cause: nil
    end
end
