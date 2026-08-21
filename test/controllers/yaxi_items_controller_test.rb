require "test_helper"

class YaxiItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @secret_bytes = "y" * 32
    @provider = Provider::Yaxi.new(
      key_id: "api-key-controller-test",
      secret: Base64.strict_encode64(@secret_bytes),
      environment: "integration"
    )
    Provider::YaxiAdapter.stubs(:build_provider).returns(@provider)
    sign_in @user
  end

  test "redirects malformed provider configuration instead of raising" do
    Provider::YaxiAdapter.stubs(:build_provider).returns(nil)

    get new_yaxi_item_path

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("yaxi_items.not_configured"), flash[:alert]
  end

  test "accepts a verified accounts result and creates linked accounts" do
    item = @family.yaxi_items.create!(name: "YAXI Connection")
    ticket = @family.yaxi_tickets.create!(
      user: @user,
      service: "Accounts",
      expires_at: 5.minutes.from_now
    )
    result_jwt = sign_result(
      ticket,
      [
        {
          iban: "DE89370400440532013000",
          bic: "COBADEFFXXX",
          currency: "EUR",
          displayName: "Main account",
          status: "Available",
          type: "Current"
        }
      ]
    )

    assert_difference [ "YaxiAccount.count", "Account.count", "AccountProvider.count" ], 1 do
      post complete_yaxi_item_path(item), params: {
        ticket_id: ticket.id,
        result_jwt: result_jwt,
        connection_info: { id: "connection-test", displayName: "Test Bank" }
      }, as: :json
    end

    assert_response :success
    assert_equal refresh_yaxi_item_path(item), response.parsed_body.fetch("redirect_url")
    assert_predicate ticket.reload, :consumed_at?
    assert_equal "Test Bank", item.reload.institution_name
  end

  test "rejects a result signed for another ticket" do
    item = @family.yaxi_items.create!(name: "YAXI Connection")
    ticket = @family.yaxi_tickets.create!(
      user: @user,
      service: "Accounts",
      expires_at: 5.minutes.from_now
    )

    post complete_yaxi_item_path(item), params: {
      ticket_id: ticket.id,
      result_jwt: sign_result(ticket, [], ticket_id: SecureRandom.uuid),
      connection_info: { id: "connection-test", displayName: "Test Bank" }
    }, as: :json

    assert_response :unprocessable_entity
    assert_nil ticket.reload.consumed_at
    assert_equal I18n.t("yaxi_items.errors.invalid_result"), response.parsed_body.fetch("error")
    assert_not_includes response.body, "another ticket"
  end

  test "applies the hash-shaped balances payload returned by YAXI" do
    item = @family.yaxi_items.create!(name: "YAXI Connection")
    item.complete_connection!(
      accounts_result: [
        {
          iban: "DE89370400440532013000",
          currency: "EUR",
          displayName: "Main account",
          status: "Available",
          type: "Current"
        }
      ],
      connection_info: { "id" => "connection-test", "displayName" => "Test Bank" }
    )
    yaxi_account = item.yaxi_accounts.first
    balances_ticket = @family.yaxi_tickets.create!(
      user: @user,
      service: "Balances",
      expires_at: 5.minutes.from_now
    )
    transaction_ticket = @family.yaxi_tickets.create!(
      user: @user,
      service: "Transactions",
      service_data: {
        account: { iban: yaxi_account.iban, currency: yaxi_account.currency },
        range: { from: 90.days.ago.to_date.iso8601 }
      },
      expires_at: 5.minutes.from_now
    )

    post apply_refresh_yaxi_item_path(item), params: {
      balances_ticket_id: balances_ticket.id,
      balances_result_jwt: sign_result(
        balances_ticket,
        {
          balances: [
            {
              account: { iban: yaxi_account.iban },
              balances: [ { amount: "123.45", currency: "EUR", balanceType: "Booked" } ]
            }
          ]
        }
      ),
      transaction_results: [
        {
          account_id: yaxi_account.id,
          ticket_id: transaction_ticket.id,
          result_jwt: sign_result(transaction_ticket, [])
        }
      ]
    }, as: :json

    assert_response :success
    assert_equal BigDecimal("123.45"), yaxi_account.reload.current_balance
    assert_predicate balances_ticket.reload, :consumed_at?
    assert_predicate transaction_ticket.reload, :consumed_at?
  end

  test "rejects a transaction ticket submitted for another linked account" do
    item = @family.yaxi_items.create!(name: "YAXI Connection")
    item.complete_connection!(
      accounts_result: [
        { iban: "DE111", currency: "EUR", displayName: "First", type: "Current" },
        { iban: "DE222", currency: "EUR", displayName: "Second", type: "Current" }
      ],
      connection_info: { "id" => "connection-test", "displayName" => "Test Bank" }
    )
    first, second = item.yaxi_accounts.order(:iban).to_a
    balances_ticket = @family.yaxi_tickets.create!(user: @user, service: "Balances", expires_at: 5.minutes.from_now)
    transaction_ticket = @family.yaxi_tickets.create!(
      user: @user,
      service: "Transactions",
      service_data: { account: { iban: first.iban, currency: first.currency } },
      expires_at: 5.minutes.from_now
    )

    post apply_refresh_yaxi_item_path(item), params: {
      balances_ticket_id: balances_ticket.id,
      balances_result_jwt: sign_result(balances_ticket, []),
      transaction_results: [
        {
          account_id: second.id,
          ticket_id: transaction_ticket.id,
          result_jwt: sign_result(transaction_ticket, [])
        }
      ]
    }, as: :json

    assert_response :unprocessable_entity
    assert_nil transaction_ticket.reload.consumed_at
    assert_nil balances_ticket.reload.consumed_at
  end

  test "refresh includes accounts identified only by account number" do
    item = @family.yaxi_items.create!(name: "YAXI Connection")
    item.complete_connection!(
      accounts_result: [ { number: "CARD-123", currency: "EUR", displayName: "Card", type: "Card" } ],
      connection_info: { "id" => "connection-test", "displayName" => "Test Bank" }
    )

    get refresh_yaxi_item_path(item)

    assert_response :success
    assert_includes response.body, "CARD-123"
  end

  test "applies balances to accounts identified only by account number" do
    item = @family.yaxi_items.create!(name: "YAXI Connection")
    item.complete_connection!(
      accounts_result: [ { number: "CARD-456", currency: "EUR", displayName: "Card", type: "Card" } ],
      connection_info: { "id" => "connection-test", "displayName" => "Test Bank" }
    )
    yaxi_account = item.yaxi_accounts.first
    balances_ticket = @family.yaxi_tickets.create!(user: @user, service: "Balances", expires_at: 5.minutes.from_now)

    post apply_refresh_yaxi_item_path(item), params: {
      balances_ticket_id: balances_ticket.id,
      balances_result_jwt: sign_result(
        balances_ticket,
        {
          balances: [
            {
              account: { number: yaxi_account.number },
              balances: [ { amount: "42.50", currency: "EUR", balanceType: "Booked" } ]
            }
          ]
        }
      ),
      transaction_results: []
    }, as: :json

    assert_response :success
    assert_equal BigDecimal("42.50"), yaxi_account.reload.current_balance
  end

  test "rejects a balance whose currency does not match the connected account" do
    item = @family.yaxi_items.create!(name: "YAXI Connection")
    item.complete_connection!(
      accounts_result: [
        { iban: "DE123", currency: "EUR", displayName: "Euro account", type: "Current" },
        { iban: "DE123", currency: "USD", displayName: "Dollar account", type: "Current" }
      ],
      connection_info: { "id" => "connection-test", "displayName" => "Test Bank" }
    )
    balances_ticket = @family.yaxi_tickets.create!(user: @user, service: "Balances", expires_at: 5.minutes.from_now)

    post apply_refresh_yaxi_item_path(item), params: {
      balances_ticket_id: balances_ticket.id,
      balances_result_jwt: sign_result(
        balances_ticket,
        [
          {
            account: { iban: "DE123", currency: "GBP" },
            balances: [ { amount: "42.50", currency: "GBP", balanceType: "Booked" } ]
          }
        ]
      ),
      transaction_results: []
    }, as: :json

    assert_response :unprocessable_entity
    assert_nil balances_ticket.reload.consumed_at
    assert item.yaxi_accounts.all? { |account| account.current_balance.nil? }
  end

  private

    def sign_result(ticket, data, ticket_id: ticket.id)
      JWT.encode(
        { data: { data: data, ticketId: ticket_id, timestamp: Time.current.iso8601 }, exp: 5.minutes.from_now.to_i },
        @secret_bytes,
        "HS256",
        { kid: "api-key-controller-test" }
      )
    end
end
