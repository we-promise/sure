require "test_helper"

class Provider::AccountData::TradeRepublic::TimelineGroupsTest < ActiveSupport::TestCase
  setup do
    @client = mock("bounded timeline transport")
    @groups = []
    @generation_id = SecureRandom.uuid
    @bindings = {
      "DE123" => { "resource" => "activities", "account_id" => "portfolio", "account_currency" => "EUR" },
      "cash:DE123" => { "resource" => "activities", "account_id" => "cash", "account_currency" => "EUR" }
    }
  end

  test "both topics and details are durable before the group is complete" do
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([ cash_event("first") ]))
    @client.expects(:get_event_detail).with(event_id: "first").returns(account: owner, response: {})
    @client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil).returns(response([ cash_event("second") ]))
    @client.expects(:get_event_detail).with(event_id: "second").returns(account: owner, response: {})
    first = advance
    refute first.complete?
    assert_empty first.account_pages
    second = advance
    refute second.complete?
    assert_equal [ "trade_republic_event_first" ], second.account_pages.fetch("cash:DE123").records.map { |record| record[:external_id] }
    assert_empty advance.account_pages
    assert advance.complete?
    assembled = Ingestion::TransactionGroupAssembler.new.assemble(@groups)
    assert_empty assembled.fetch("DE123").records
    assert_equal %w[trade_republic_event_first trade_republic_event_second], assembled.fetch("cash:DE123").records.map { |record| record[:external_id] }
    assert_nil assembled.fetch("cash:DE123").checkpoint_cursor
  end

  test "the first exact event ID wins globally across topic pages without financial matching" do
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([ cash_event("same"), cash_event("same", amount: "99") ]))
    @client.expects(:get_event_detail).with(event_id: "same").once.returns(account: owner, response: {})
    @client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil)
      .returns(response([ cash_event("same", amount: "500"), cash_event("different") ]))
    @client.expects(:get_event_detail).with(event_id: "different").once.returns(account: owner, response: {})
    4.times { advance }
    records = Ingestion::TransactionGroupAssembler.new.assemble(@groups).fetch("cash:DE123").records
    assert_equal %w[trade_republic_event_same trade_republic_event_different], records.map { |record| record[:external_id] }
    assert_equal [ BigDecimal("-10"), BigDecimal("-10") ], records.map { |record| record[:amount] }
  end

  test "a duplicate event cannot move between cash and securities routes" do
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([ cash_event("same") ]))
    @client.expects(:get_event_detail).with(event_id: "same").returns(account: owner, response: {})
    2.times { advance }
    @client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil).returns(response([ cash_event("same").merge(eventType: "ORDER_EXECUTED") ]))
    assert_raises(Provider::AccountData::InvalidResponse) { advance }
    assert @groups.none?(&:complete?)
  end

  test "unknown categories stay captured and cannot erase another event with the same financial values" do
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([ cash_event("unknown").merge(eventType: "UNKNOWN") ]))
    @client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil).returns(response([]))
    @client.expects(:get_event_detail).never
    2.times { advance }
    assert @groups.last.complete?
    assert_equal "unknown", @groups.first.evidence.dig("trade_republic_timeline", "response", "response", "items", 0, "id")
    assert Ingestion::TransactionGroupAssembler.new.assemble(@groups).values.all? { |page| page.records.empty? }
  end

  test "more than one detail slice resumes without repeating any completed response" do
    rows = Array.new(33) { |index| cash_event("event-#{index}") }
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).once.returns(response(rows))
    rows.each { |row| @client.expects(:get_event_detail).with(event_id: row[:id]).once.returns(account: owner, response: {}) }
    @client.expects(:get_timeline_page).with(topic: "timelineActivityLog", cursor: nil).returns(response([]))
    advance
    first_details = advance
    assert_empty first_details.account_pages
    assert_equal 32, first_details.evidence.dig("trade_republic_timeline", "details").size
    assert_equal 33, advance.account_pages.fetch("cash:DE123").records.size
    assert advance.complete?
  end

  test "missing foreign or changed original context cannot reuse a continuation" do
    @client.expects(:get_timeline_page).returns(response([]))
    advance
    @client.expects(:get_timeline_page).never
    original = @generation_id
    @generation_id = SecureRandom.uuid
    assert_raises(Provider::AccountData::InvalidResponse) { advance }
    @generation_id = original
    @bindings["cash:DE123"]["account_id"] = nil
    assert_raises(Provider::AccountData::InvalidResponse) { advance }
  end

  test "empty items with a continuation and missing event identities cannot claim completion" do
    [ response([], after: "next"), response([ cash_event("event").except(:id) ]) ].each do |value|
      @client.expects(:get_timeline_page).returns(value)
      assert_raises(Provider::AccountData::InvalidResponse) { advance }
      assert_empty @groups
    end
  end

  test "repeated upstream cursors leave both-topic completion unresolved" do
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: nil).returns(response([ cash_event("unknown").merge(eventType: "UNKNOWN") ], after: "next"))
    @client.expects(:get_timeline_page).with(topic: "timelineTransactions", cursor: "next").returns(response([ cash_event("unknown-2").merge(eventType: "UNKNOWN") ], after: "next"))
    advance
    assert_raises(Provider::AccountData::IncompletePage) { advance }
    refute @groups.first.complete?
  end

  test "a failed detail keeps the raw page but cannot generate an account child" do
    @client.expects(:get_timeline_page).returns(response([ cash_event("first") ]))
    advance
    @client.expects(:get_event_detail).raises(Provider::AccountData::Error, "unavailable")
    assert_raises(Provider::AccountData::Error) { advance }
    assert_equal 1, @groups.size
    assert_empty @groups.first.account_pages
  end

  test "cumulative detail bytes stop the request before later details are fetched" do
    rows = [ cash_event("first"), cash_event("second"), cash_event("third") ]
    @client.expects(:get_timeline_page).returns(response(rows))
    advance
    # One small detail is valid; the second alone is over the typed bound.
    @client.expects(:get_event_detail).with(event_id: "first").returns(account: owner, response: {})
    @client.expects(:get_event_detail).with(event_id: "second").returns(account: owner,
      response: { "text" => "x" * Provider::AccountData::TradeRepublic::TimelineGroups::MAX_CAPTURE_BYTES })
    @client.expects(:get_event_detail).with(event_id: "third").never
    assert_raises(Provider::AccountData::IncompletePage) { advance }
    assert_equal 1, @groups.size
  end

  private
    def advance
      # Rebuild the adapter and round-trip every captured page on every step:
      # continuation cannot rely on the previous worker's instance variables.
      adapter = Provider::AccountData::TradeRepublic.new(client: @client, timezone: "UTC", observed_at: Time.utc(2026, 9, 15),
        linked_cash_ids: @bindings["cash:DE123"]["account_id"] ? [ "cash:DE123" ] : [])
      group = adapter.fetch_activity_group(start_cursor: "retained-old-checkpoint", generation_id: @generation_id,
        cursor: @groups.last&.next_cursor || "retained-old-checkpoint", captured_groups: @groups, accounts: @bindings)
      @groups << Ingestion::TransactionGroupCodec.load(Ingestion::TransactionGroupCodec.dump(group))
      group
    end

    def owner
      { securitiesAccountNumber: "DE123", currency: "EUR" }
    end

    def cash_event(id, amount: "10")
      { id: id, timestamp: "2026-09-12T12:00:00Z", eventType: "INCOMING_TRANSFER", title: "Transfer", amount: { value: amount, currency: "EUR" } }
    end

    def response(rows, after: nil)
      { account: owner, response: { items: rows }, next_cursor: after }
    end
end
