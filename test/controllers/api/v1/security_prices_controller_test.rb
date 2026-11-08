# frozen_string_literal: true

require "test_helper"

class Api::V1::SecurityPricesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @account = accounts(:investment)
    @security = securities(:aapl)
    @ticker = @security.ticker
    @security_price = security_prices(:one)
    @eur_price = Security::Price.create!(
      security: @security,
      date: @security_price.date,
      price: BigDecimal("250.5000"),
      currency: "EUR"
    )

    other_account = families(:empty).accounts.create!(
      name: "Other Investment Account",
      accountable: Investment.new,
      balance: 1000,
      currency: "USD"
    )
    @other_security = Security.create!(ticker: "GOOG#{SecureRandom.hex(4).upcase}", name: "Alphabet Inc.", country_code: "US")
    other_account.holdings.create!(
      security: @other_security,
      date: Date.parse("2024-01-15"),
      qty: 1,
      price: 100,
      amount: 100,
      currency: "USD"
    )
    @other_price = Security::Price.create!(
      security: @other_security,
      date: Date.parse("2024-01-15"),
      price: 100,
      currency: "USD"
    )
  end

  test "lists prices for securities referenced by accessible family investment data" do
    get api_v1_security_prices_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    price_ids = response_data["security_prices"].map { |price| price["id"] }

    assert_includes price_ids, @security_price.id
    assert_not_includes price_ids, @other_price.id
    assert response_data.key?("pagination")
  end

  test "shows a scoped security price" do
    get api_v1_security_price_url(@security_price), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @security_price.id, response_data["id"]
    assert_equal @security_price.date.iso8601, response_data["date"]
    assert_equal "215.0000", response_data["price_amount"]
    assert_equal @security.id, response_data.dig("security", "id")
  end

  test "legacy invalid currencies are omitted from index and unavailable through show" do
    @security_price.update_column(:currency, "")

    get api_v1_security_prices_url, headers: api_headers(@api_key)
    assert_response :success
    ids = JSON.parse(response.body)["security_prices"].map { |price| price["id"] }
    assert_not_includes ids, @security_price.id
    assert_includes ids, @eur_price.id

    get api_v1_security_price_url(@security_price), headers: api_headers(@api_key)
    assert_response :not_found
    assert_equal "record_not_found", JSON.parse(response.body)["error"]
  end

  test "legacy currency formatting is safely normalized in filtered index and show" do
    @security_price.update_column(:currency, " \tusd\n ")

    get api_v1_security_prices_url, params: { currency: "USD" }, headers: api_headers(@api_key)
    assert_response :success
    price = JSON.parse(response.body)["security_prices"].find { |row| row["id"] == @security_price.id }
    assert_equal "USD", price.fetch("currency")

    get api_v1_security_price_url(@security_price), headers: api_headers(@api_key)
    assert_response :success
    assert_equal "USD", JSON.parse(response.body)["currency"]
    assert_equal " \tusd\n ", @security_price.reload[:currency]
  end

  test "returns not found for another family's security price" do
    get api_v1_security_price_url(@other_price), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed security price id" do
    get api_v1_security_price_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters security prices by security_id" do
    get api_v1_security_prices_url, params: { security_id: @security.id }, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["security_prices"].map { |price| price["id"] }, @security_price.id
    assert response_data["security_prices"].all? { |price| price.dig("security", "id") == @security.id }
  end

  test "filters security prices by date range and provisional status" do
    get api_v1_security_prices_url,
        params: { start_date: @security_price.date.iso8601, end_date: @security_price.date.iso8601, currency: "USD", provisional: false },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal [ @security_price.id ], response_data["security_prices"].map { |price| price["id"] }
  end

  test "rejects blank provisional filter" do
    get api_v1_security_prices_url,
        params: { provisional: "" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "provisional must be true or false"
  end

  test "filters security prices by currency" do
    get api_v1_security_prices_url,
        params: { currency: " usd " },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["security_prices"].map { |price| price["id"] }, @security_price.id
    assert_not_includes response_data["security_prices"].map { |price| price["id"] }, @eur_price.id
  end

  test "rejects malformed provisional filter" do
    get api_v1_security_prices_url,
        params: { provisional: "maybe" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_includes response_data["errors"], "provisional must be true or false"
  end

  test "caps per_page at documented maximum" do
    get api_v1_security_prices_url, params: { per_page: 250 }, headers: api_headers(@api_key)

    assert_response :success
    assert_equal 100, JSON.parse(response.body).dig("pagination", "per_page")
  end

  test "rejects malformed security_id filter" do
    get api_v1_security_prices_url, params: { security_id: "not-a-uuid" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "rejects invalid date filters" do
    get api_v1_security_prices_url, params: { start_date: "01/15/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "requires authentication" do
    get api_v1_security_prices_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_security_prices_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end

  test "imports closes for an offline security the caller holds and syncs its accounts" do
    security = offline_security_held_by(@account)
    Account.any_instance.expects(:sync_later).once

    with_self_hosting do
      post api_v1_security_prices_url,
           params: { security_id: security.id, prices: [ close(2.days.ago, "21.5"), close(1.day.ago, "22") ] },
           headers: api_headers(write_key), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal({ "security_id" => security.id, "currency" => "AUD", "created" => 2, "updated" => 0,
                   "start_date" => 2.days.ago.to_date.iso8601, "end_date" => 1.day.ago.to_date.iso8601 }, body)
    assert_equal [ BigDecimal("21.5"), BigDecimal("22") ], security.prices.order(:date).pluck(:price)
  end

  test "resubmitting a date updates it" do
    security = offline_security_held_by(@account)
    security.prices.create!(date: 1.day.ago.to_date, price: 20, currency: "AUD")
    Account.any_instance.stubs(:sync_later)

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: security.id, prices: [ close(1.day.ago, "24") ] },
           headers: api_headers(write_key), as: :json
    end

    assert_response :success
    assert_equal [ 0, 1 ], JSON.parse(response.body).values_at("created", "updated")
    assert_equal BigDecimal("24"), security.prices.sole.price
  end

  test "a read-only key cannot import prices" do
    security = offline_security_held_by(@account)

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: security.id, prices: [ close(1.day.ago, "20") ] },
           headers: api_headers(@api_key), as: :json
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
    assert_empty security.prices
  end

  test "managed mode refuses imports because prices are shared across families" do
    security = offline_security_held_by(@account)

    post api_v1_security_prices_url, params: { security_id: security.id, prices: [ close(1.day.ago, "20") ] },
         headers: api_headers(write_key), as: :json

    assert_response :forbidden
    assert_equal "self_hosted_only", JSON.parse(response.body)["error"]
    assert_empty security.prices
  end

  test "a security the caller cannot write to is not found, however it is named" do
    other_offline = Security.create!(ticker: "OTHER#{SecureRandom.hex(3).upcase}", offline: true)
    other_account = families(:empty).accounts.create!(name: "Theirs", accountable: Investment.new, balance: 1, currency: "AUD")
    other_account.entries.create!(
      date: 3.days.ago.to_date, name: "Buy", amount: 1, currency: "AUD",
      entryable: Trade.new(security: other_offline, qty: 1, price: 1, currency: "AUD")
    )
    shared_read_only = offline_security_held_by(@account)
    @account.update_columns(owner_id: users(:family_member).id)
    AccountShare.create!(account: @account, user: @user, permission: "read_only")
    # The caller does hold an offline security, so a lookup that lost the
    # requested id would find this one instead of returning 404.
    own_account = @family.accounts.create!(name: "Mine", owner: @user, accountable: Investment.new, balance: 1, currency: "AUD")
    own_security = offline_security_held_by(own_account)

    [ other_offline.id, shared_read_only.id, SecureRandom.uuid, "not-a-uuid" ].each do |security_id|
      with_self_hosting do
        post api_v1_security_prices_url, params: { security_id: security_id, prices: [ close(1.day.ago, "20") ] },
             headers: api_headers(write_key), as: :json
      end

      assert_response :not_found, "expected 404 for #{security_id}"
      assert_equal "record_not_found", JSON.parse(response.body)["error"]
    end
    assert_empty other_offline.prices
    assert_empty shared_read_only.prices
    assert_empty own_security.prices
  end

  test "an online security is refused" do
    Account.any_instance.expects(:sync_later).never
    before = @security.prices.order(:date, :currency).pluck(:date, :currency, :price)

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: @security.id, prices: [ close(1.day.ago, "20", currency: "USD") ] },
           headers: api_headers(write_key), as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body["error"]
    assert_equal [ { "index" => nil, "message" => "prices can only be imported for a security no provider tracks" } ], body["errors"]
    assert_equal before, @security.prices.order(:date, :currency).pluck(:date, :currency, :price)
  end

  test "a bad row rejects the whole batch with its index" do
    security = offline_security_held_by(@account)
    Account.any_instance.expects(:sync_later).never

    with_self_hosting do
      post api_v1_security_prices_url,
           params: { security_id: security.id, prices: [ close(2.days.ago, "21"), close(Date.current + 1, "22") ] },
           headers: api_headers(write_key), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal [ { "index" => 1, "message" => "date must not be in the future" } ], JSON.parse(response.body)["errors"]
    assert_empty security.prices
  end

  # At 12:00 UTC on 7 Nov it is already 8 Nov in Auckland (UTC+13), so the
  # family's today is importable and its tomorrow is not. Judged in UTC, the
  # first row would be rejected as a future date.
  test "the future-date check uses the family's time zone" do
    @family.update!(timezone: "Pacific/Auckland")
    security = offline_security_held_by(@account)
    Account.any_instance.stubs(:sync_later)

    travel_to Time.utc(2026, 11, 7, 12) do
      with_self_hosting do
        post api_v1_security_prices_url,
             params: { security_id: security.id, prices: [ close(Date.new(2026, 11, 8), "21") ] },
             headers: api_headers(write_key), as: :json
        assert_response :ok

        post api_v1_security_prices_url,
             params: { security_id: security.id, prices: [ close(Date.new(2026, 11, 9), "22") ] },
             headers: api_headers(write_key), as: :json
        assert_response :unprocessable_entity
        assert_equal [ { "index" => 0, "message" => "date must not be in the future" } ], JSON.parse(response.body)["errors"]
      end
    end

    assert_equal [ [ Date.new(2026, 11, 8), 21 ] ], security.prices.pluck(:date, :price)
  end

  # An unlinked account's sync rebuilds its holdings from trades and deletes
  # the rest, so accepting this import would queue a sync that removes the
  # position being priced.
  test "an unlinked account's holding with no trade behind it is not found" do
    security = offline_security_held_without_trade(@account)
    Account.any_instance.expects(:sync_later).never

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: security.id, prices: [ close(1.day.ago, "20") ] },
           headers: api_headers(write_key), as: :json
    end

    assert_response :not_found
    assert_empty security.prices
  end

  # A linked account's holdings come from its provider, and its (reverse) sync
  # keeps them, so a holding there is enough.
  test "a linked account's holding is enough, with no trade" do
    linked = @family.accounts.create!(name: "Linked", owner: @user, accountable: Investment.new, balance: 200, currency: "AUD")
    AccountProvider.create!(account: linked, provider: lunchflow_accounts(:investment_account))
    security = offline_security_held_without_trade(linked)
    Account.any_instance.expects(:sync_later).once

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: security.id, prices: [ close(1.day.ago, "21") ] },
           headers: api_headers(write_key), as: :json
    end

    assert_response :ok
    assert_equal [ BigDecimal("21") ], security.prices.pluck(:price)
  end

  # The sync the import queues, run for real: the trade-backed holding is
  # rebuilt at the imported close rather than purged.
  test "the queued sync revalues the position at the imported close" do
    security = offline_security_held_by(@account)

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: security.id, prices: [ close(1.day.ago, "35") ] },
           headers: api_headers(write_key), as: :json
    end
    assert_response :ok

    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    holding = @account.holdings.find_by(security: security, date: 1.day.ago.to_date)

    assert_not_nil holding, "the sync removed the priced position"
    assert_equal BigDecimal("35"), holding.price
    assert_equal BigDecimal("350"), holding.amount
  end

  # Security prices are shared across families, so a guest's read_write key
  # must not write them, even through an account the guest could write to.
  test "a guest cannot import prices" do
    guest = users(:intro_user)
    account = guest.family.accounts.create!(name: "Guest's", owner: guest, accountable: Investment.new, balance: 200, currency: "AUD")
    security = offline_security_held_by(account)
    key = ApiKey.create!(user: guest, name: "Guest Key", scopes: [ "read_write" ], source: "mobile", display_key: "guest_#{SecureRandom.hex(8)}")

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: security.id, prices: [ close(1.day.ago, "20") ] },
           headers: api_headers(key), as: :json
    end

    assert_response :forbidden
    assert_empty security.prices
  end

  test "prices must be a list" do
    security = offline_security_held_by(@account)

    with_self_hosting do
      post api_v1_security_prices_url, params: { security_id: security.id, prices: "21" },
           headers: api_headers(write_key), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal [ { "index" => nil, "message" => "prices must be a list" } ], JSON.parse(response.body)["errors"]
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def write_key
      @write_key ||= ApiKey.create!(
        user: @user,
        name: "Test Write Key",
        scopes: [ "read_write" ],
        source: "mobile",
        display_key: "test_write_#{SecureRandom.hex(8)}"
      )
    end

    # A manual-ticker security as it arises: bought by a trade, which the
    # account's holdings are built from.
    def offline_security_held_by(account)
      Security.create!(ticker: "MYFUND#{SecureRandom.hex(3).upcase}", name: "My Fund", offline: true).tap do |security|
        account.entries.create!(
          date: 3.days.ago.to_date, name: "Buy", amount: 200, currency: "AUD",
          entryable: Trade.new(security: security, qty: 10, price: 20, currency: "AUD")
        )
        account.holdings.create!(security: security, date: 3.days.ago.to_date, qty: 10, price: 20, amount: 200, currency: "AUD")
      end
    end

    def offline_security_held_without_trade(account)
      Security.create!(ticker: "HELD#{SecureRandom.hex(3).upcase}", name: "Held Fund", offline: true).tap do |security|
        account.holdings.create!(security: security, date: 3.days.ago.to_date, qty: 10, price: 20, amount: 200, currency: "AUD")
      end
    end

    def close(date, price, currency: "AUD")
      { date: date.to_date.iso8601, price: price, currency: currency }
    end
end
