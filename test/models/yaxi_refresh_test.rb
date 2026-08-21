require "test_helper"

class YaxiRefreshTest < ActiveSupport::TestCase
  setup do
    user = users(:family_admin)
    @secret_bytes = "y" * 32
    provider = Provider::Yaxi.new(
      key_id: "api-key-refresh-test",
      secret: Base64.strict_encode64(@secret_bytes),
      environment: "integration"
    )
    Provider::YaxiAdapter.stubs(:build_provider).returns(provider)

    @item = user.family.yaxi_items.create!(name: "YAXI Connection")
    @yaxi_account = @item.yaxi_accounts.create!(
      external_id: YaxiAccount.external_id_for(iban: "DE123", currency: "EUR"),
      iban: "DE123",
      name: "Euro account",
      currency: "EUR",
      account_type: "Current"
    )
    @account = @yaxi_account.ensure_linked_account!
    @refresh = YaxiRefresh.new(item: @item, user: user, provider: provider)
  end

  test "uses a bounded overlap based only on YAXI entries" do
    yaxi_date = 5.days.ago.to_date
    create_entry!(date: yaxi_date, source: "yaxi", external_id: "yaxi-existing")
    create_entry!(date: 10.days.from_now.to_date, source: "manual", external_id: "manual-future")

    preparation = @refresh.preparation
    ticket = YaxiTicket.find(preparation.fetch(:transaction_tickets).sole.fetch(:ticket_id))

    assert_equal((yaxi_date - YaxiRefresh::TRANSACTION_LOOKBACK).iso8601, ticket.service_data.dig("range", "from"))
  end

  test "starts at the 90-day boundary when no YAXI entries exist" do
    create_entry!(date: 10.days.from_now.to_date, source: "manual", external_id: "manual-future")

    preparation = @refresh.preparation
    ticket = YaxiTicket.find(preparation.fetch(:transaction_tickets).sole.fetch(:ticket_id))

    assert_equal 90.days.ago.to_date.iso8601, ticket.service_data.dig("range", "from")
  end

  test "extends the overlap to include the oldest pending YAXI entry" do
    pending_date = 30.days.ago.to_date
    create_entry!(
      date: pending_date,
      source: "yaxi",
      external_id: "yaxi-pending",
      extra: { yaxi: { pending: true } }
    )
    create_entry!(date: 1.day.ago.to_date, source: "yaxi", external_id: "yaxi-recent")

    preparation = @refresh.preparation
    ticket = YaxiTicket.find(preparation.fetch(:transaction_tickets).sole.fetch(:ticket_id))

    assert_equal pending_date.iso8601, ticket.service_data.dig("range", "from")
  end

  test "rejects currency mismatches and ambiguous references" do
    @item.yaxi_accounts.create!(
      external_id: YaxiAccount.external_id_for(iban: "DE123", currency: "USD"),
      iban: "DE123",
      name: "Dollar account",
      currency: "USD",
      account_type: "Current"
    )

    assert_equal @yaxi_account, @refresh.send(:find_account, iban: "DE123", currency: "EUR")
    assert_nil @refresh.send(:find_account, iban: "DE123", currency: "GBP")
    assert_nil @refresh.send(:find_account, iban: "DE123")
  end

  private

    def create_entry!(date:, source:, external_id:, extra: nil)
      @account.entries.create!(
        date: date,
        name: external_id,
        amount: 1,
        currency: "EUR",
        source: source,
        external_id: external_id,
        entryable: Transaction.new(extra: extra || {})
      )
    end
end
