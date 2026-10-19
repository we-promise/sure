require "test_helper"

class ScalableItem::HistoryReaderTest < ActiveSupport::TestCase
  test "reads every cursor page twice and attaches the verified summary status" do
    first = summary("cash-1", status: "CONFIRMED")
    second = summary("cash-2", amount: "-1.00", status: "SETTLED")
    pages = [
      summary_page([ first ], total: 2, cursor: "next-page"),
      summary_page([ second ], total: 2)
    ]
    provider, calls = provider_with(summary_responses: pages + pages, details: [ detail(first), detail(second) ])

    result = ScalableItem::HistoryReader.new(
      provider: provider,
      account_id: "broker-account",
      portfolio_id: "broker-portfolio"
    ).read

    assert_equal %i[
      broker_transactions broker_transactions broker_transaction_details broker_transaction_details
      broker_transactions broker_transactions
    ], calls.map { |call| call.fetch(:operation) }
    assert_equal [ "cash-1", "cash-2" ], result.map { |row| row.fetch("id") }
    assert_equal [ "CONFIRMED", "SETTLED" ], result.map { |row| row.fetch("summary_status") }
    assert_equal [ nil, "next-page", nil, "next-page" ], calls.select { |call| call.fetch(:operation) == :broker_transactions }
      .map { |call| call.fetch(:variables).dig("input", "cursor") }
    assert_equal [ "cash-1", "cash-2" ], calls.select { |call| call.fetch(:operation) == :broker_transaction_details }
      .map { |call| call.fetch(:variables).fetch("transactionId") }

    input = calls.first.fetch(:variables).fetch("input")
    assert_equal 100, input.fetch("pageSize")
    assert_nil input.fetch("fromTime")
    assert_nil input.fetch("toTime")
    assert_equal true, input.fetch("includeReinvestmentSubtypes")
  end

  test "rejects a summary that changes between the details and second complete pass" do
    first = summary("cash-1", amount: "50.00")
    changed = summary("cash-1", amount: "51.00")
    provider, calls = provider_with(
      summary_responses: [ summary_page([ first ]), summary_page([ changed ]) ],
      details: [ detail(first) ]
    )

    error = assert_raises(Provider::Scalable::Error) do
      reader(provider).read
    end

    assert_equal "history_changed", error.code
    assert_equal %i[broker_transactions broker_transaction_details broker_transactions],
      calls.map { |call| call.fetch(:operation) }
  end

  test "rejects duplicate IDs and incomplete totals" do
    duplicate = summary("cash-1")
    cases = [
      [ summary_page([ duplicate, duplicate ], total: 2) ],
      [ summary_page([ duplicate ], total: 2) ]
    ]

    cases.each do |pages|
      provider, = provider_with(summary_responses: pages, details: [])
      error = assert_raises(Provider::Scalable::Error) { reader(provider).read }
      assert_equal "history_incomplete", error.code
    end
  end

  test "rejects missing and repeated cursors" do
    row = summary("cash-1")
    missing_cursor = summary_page([ row ], total: 2)
    repeated_cursor = [
      summary_page([ row ], total: 3, cursor: "same-cursor"),
      summary_page([ summary("cash-2") ], total: 3, cursor: "same-cursor")
    ]

    [ [ missing_cursor ], repeated_cursor ].each do |pages|
      provider, = provider_with(summary_responses: pages, details: [])
      error = assert_raises(Provider::Scalable::Error) { reader(provider).read }
      assert_equal "history_incomplete", error.code
    end
  end

  test "rejects noncash summaries and details that do not match their summary" do
    noncash = summary("trade-1").merge(
      "__typename" => "BrokerSecurityTransactionSummary",
      "type" => "TRADE"
    )
    provider, = provider_with(summary_responses: [ summary_page([ noncash ]) ], details: [])
    unsupported = assert_raises(Provider::Scalable::Error) { reader(provider).read }
    assert_equal "history_unsupported", unsupported.code

    row = summary("cash-1")
    wrong_detail = detail(row).dig("account", "brokerPortfolio", "transactionDetails").merge("currency" => "USD")
    provider, = provider_with(summary_responses: [ summary_page([ row ]), summary_page([ row ]) ], details: [ wrapped_detail(wrong_detail) ])
    changed = assert_raises(Provider::Scalable::Error) { reader(provider).read }
    assert_equal "history_changed", changed.code
  end

  test "rejects detail cancellation state that conflicts with its summary" do
    row = summary("cash-1")
    detail_row = detail(row).dig("account", "brokerPortfolio", "transactionDetails").merge("isCancellation" => true)
    provider, calls = provider_with(
      summary_responses: [ summary_page([ row ]) ],
      details: [ wrapped_detail(detail_row) ]
    )

    error = assert_raises(Provider::Scalable::Error) { reader(provider).read }

    assert_equal "history_changed", error.code
    assert_equal %i[broker_transactions broker_transaction_details], calls.map { |call| call.fetch(:operation) }
  end

  test "rejects summary and detail responses outside the requested account scope" do
    row = summary("cash-1")
    wrong_account_page = summary_page([ row ]).deep_dup
    wrong_account_page["account"]["id"] = "another-account"
    provider, = provider_with(summary_responses: [ wrong_account_page ], details: [])
    error = assert_raises(Provider::Scalable::Error) { reader(provider).read }
    assert_equal "history_changed", error.code

    wrong_portfolio_detail = detail(row).deep_dup
    wrong_portfolio_detail["account"]["brokerPortfolio"]["id"] = "another-portfolio"
    provider, = provider_with(summary_responses: [ summary_page([ row ]), summary_page([ row ]) ], details: [ wrong_portfolio_detail ])
    error = assert_raises(Provider::Scalable::Error) { reader(provider).read }
    assert_equal "history_changed", error.code
  end

  test "rejects row and request limits before returning partial history" do
    oversized = { "account" => { "id" => "broker-account", "brokerPortfolio" => {
      "id" => "broker-portfolio", "moreTransactions" => {
        "cursor" => nil, "total" => ScalableItem::HistoryReader::MAX_ROWS + 1, "transactions" => []
      }
    } } }
    provider, calls = provider_with(summary_responses: [ oversized ], details: [])
    error = assert_raises(Provider::Scalable::Error) { reader(provider).read }
    assert_equal "history_incomplete", error.code
    assert_equal 1, calls.length

    page_responses = (1..101).map do |index|
      summary_page([ summary("cash-#{index}") ], total: 101, cursor: index < 101 ? "cursor-#{index}" : nil)
    end
    provider, calls = provider_with(summary_responses: page_responses, details: [])
    error = assert_raises(Provider::Scalable::Error) { reader(provider).read }
    assert_equal "history_incomplete", error.code
    assert_equal ScalableItem::HistoryReader::MAX_PAGES, calls.length

    rows = (1..1_000).map { |index| summary("cash-#{index}") }
    rows_by_id = rows.index_by { |row| row.fetch("id") }
    calls = []
    summary_page_builder = method(:summary_page)
    detail_builder = method(:detail)
    provider = Object.new
    provider.define_singleton_method(:read) do |operation, variables:|
      calls << { operation: operation, variables: variables }
      if operation == :broker_transactions
        cursor = variables.dig("input", "cursor")
        offset = cursor ? cursor.delete_prefix("offset-").to_i : 0
        page_rows = rows.slice(offset, 100)
        next_offset = offset + page_rows.length
        next_cursor = next_offset < rows.length ? "offset-#{next_offset}" : nil
        summary_page_builder.call(page_rows, total: rows.length, cursor: next_cursor)
      else
        id = variables.fetch("transactionId")
        row = rows_by_id.fetch(id)
        detail_builder.call(row)
      end
    end

    error = assert_raises(Provider::Scalable::Error) { reader(provider).read }
    assert_equal "history_incomplete", error.code
    assert_equal ScalableItem::HistoryReader::MAX_REQUESTS, calls.length
  end

  private

    def reader(provider)
      ScalableItem::HistoryReader.new(provider: provider, account_id: "broker-account", portfolio_id: "broker-portfolio")
    end

    def provider_with(summary_responses:, details:)
      calls = []
      summary_index = 0
      details_by_id = details.index_by do |response|
        response.dig("account", "brokerPortfolio", "transactionDetails", "id")
      end
      provider = Object.new
      provider.define_singleton_method(:read) do |operation, variables:|
        calls << { operation: operation, variables: variables }
        if operation == :broker_transactions
          response = summary_responses.fetch(summary_index)
          summary_index += 1
          response
        else
          details_by_id.fetch(variables.fetch("transactionId"))
        end
      end
      [ provider, calls ]
    end

    def summary_page(rows, total: rows.length, cursor: nil)
      {
        "account" => {
          "id" => "broker-account",
          "brokerPortfolio" => {
            "id" => "broker-portfolio",
            "moreTransactions" => {
              "cursor" => cursor,
              "total" => total,
              "transactions" => rows
            }
          }
        }
      }
    end

    def summary(id, amount: "50.00", status: "CONFIRMED")
      {
        "__typename" => "BrokerCashTransactionSummary",
        "id" => id,
        "currency" => "EUR",
        "type" => "CASH_TRANSACTION",
        "status" => status,
        "isCancellation" => false,
        "lastEventDateTime" => "2026-10-19T00:00:00Z",
        "cashTransactionType" => amount.to_s.start_with?("-") ? "WITHDRAWAL" : "DEPOSIT",
        "amount" => amount
      }
    end

    def detail(row)
      wrapped_detail(
        "__typename" => "BrokerCashTransaction",
        "id" => row.fetch("id"),
        "currency" => row.fetch("currency"),
        "type" => row.fetch("type"),
        "lastEventDateTime" => row.fetch("lastEventDateTime"),
        "isPending" => false,
        "isCancellation" => false,
        "cashTransactionType" => row.fetch("cashTransactionType"),
        "amount" => row.fetch("amount"),
        "description" => "Synthetic cash movement",
        "cashTransactionHistory" => [ { "state" => "SETTLED" } ]
      )
    end

    def wrapped_detail(detail_row)
      {
        "account" => {
          "id" => "broker-account",
          "brokerPortfolio" => {
            "id" => "broker-portfolio",
            "transactionDetails" => detail_row
          }
        }
      }
    end
end
