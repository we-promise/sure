require "test_helper"

class WiseItem::ImporterTest < ActiveSupport::TestCase
  class FakeWiseProvider
    attr_reader :calls

    def initialize(balances: nil, savings_balances: nil, borderless_accounts: nil,
                   transfers: nil, activities: nil, raise_on: {})
      @balances = balances || [ standard_balance ]
      @savings_balances = savings_balances || []
      @borderless_accounts = borderless_accounts || [ borderless_account ]
      @transfers = transfers || []
      @activities = activities || []
      @raise_on = raise_on
      @calls = []
    end

    def get_balances(profile_id)
      @calls << :get_balances
      raise_if(:get_balances)
      @balances
    end

    def get_savings_balances(profile_id)
      @calls << :get_savings_balances
      raise_if(:get_savings_balances)
      @savings_balances
    end

    def get_borderless_accounts(profile_id)
      @calls << :get_borderless_accounts
      raise_if(:get_borderless_accounts)
      @borderless_accounts
    end

    def get_transfers(profile_id, limit: 100, offset: 0)
      @calls << :get_transfers
      @transfers
    end

    def get_activities(profile_id, cursor: nil, size: 100)
      @calls << :get_activities
      raise_if(:get_activities)
      { "activities" => @activities, "cursor" => nil }
    end

    private

      def raise_if(method)
        error = @raise_on[method]
        raise Provider::Wise::WiseError.new(error, :fetch_failed) if error
      end

      def standard_balance
        {
          "id" => "10000001",
          "amount" => { "value" => 1964.88, "currency" => "EUR" },
          "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
          "type" => "STANDARD"
        }
      end

      def borderless_account
        {
          "id" => 88888001,
          "recipientId" => 99999001,
          "balances" => [ { "id" => 10000001 } ]
        }
      end
  end

  setup do
    @family = families(:empty)
    @wise_item = WiseItem.create!(
      family: @family,
      name: "Test Wise",
      token: "test_token",
      profile_id: "11111111",
      profile_type: :business
    )
  end

  # STANDARD balance import

  test "imports STANDARD balances and creates WiseAccount records" do
    provider = FakeWiseProvider.new

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:success]
    assert_equal 1, result[:accounts_created]
    assert_equal 0, result[:accounts_updated]

    account = @wise_item.wise_accounts.first
    assert_equal "10000001", account.balance_id
    assert_equal "EUR", account.currency
    assert_not account.jar?
  end

  test "stores borderless_account_id and recipient_id in STANDARD account raw_payload" do
    provider = FakeWiseProvider.new

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    account = @wise_item.wise_accounts.find_by(balance_id: "10000001")
    assert_equal 88888001, account.raw_payload["borderless_account_id"]
    assert_equal 99999001, account.raw_payload["recipient_id"]
  end

  # SAVINGS (JAR) balance import

  test "imports SAVINGS balances and marks them as JAR" do
    savings = {
      "id" => "10000002",
      "amount" => { "value" => 11022.16, "currency" => "EUR" },
      "totalWorth" => { "value" => 11022.16, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }
    provider = FakeWiseProvider.new(savings_balances: [ savings ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    jar = @wise_item.wise_accounts.find_by(balance_id: "10000002")
    assert_not_nil jar
    assert jar.jar?
    assert_equal BigDecimal("11022.16"), jar.current_balance
    assert_equal "Jar", jar.name
  end

  test "continues if savings balances fetch fails" do
    provider = FakeWiseProvider.new(raise_on: { get_savings_balances: "forbidden" })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert result[:success]
    assert_equal 1, @wise_item.wise_accounts.count
  end

  # Transfer routing

  test "routes transfers to matching STANDARD account by source currency" do
    transfers = [
      build_transfer(id: 1, source_currency: "EUR", target_currency: "EUR", target_account: 9999),
      build_transfer(id: 2, source_currency: "USD", target_currency: "USD", target_account: 9999)
    ]
    provider = FakeWiseProvider.new(transfers: transfers)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    eur_account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_equal 1, eur_account.raw_transactions_payload.size
    assert_equal 1, eur_account.raw_transactions_payload.first["id"]
  end

  test "routes incoming transfers to account by target currency" do
    transfers = [
      build_transfer(id: 3, source_currency: "USD", target_currency: "EUR", target_account: 99999001)
    ]
    provider = FakeWiseProvider.new(transfers: transfers)

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    eur_account = @wise_item.wise_accounts.find_by(currency: "EUR")
    assert_equal 1, eur_account.raw_transactions_payload.size
  end

  # Activity routing

  test "routes INTERBALANCE activities to both JAR and STANDARD accounts" do
    savings = {
      "id" => "10000002",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }
    interbalance = build_interbalance("To <strong>Jar</strong>", resource_id: "5001")
    provider = FakeWiseProvider.new(savings_balances: [ savings ], activities: [ interbalance ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    jar = @wise_item.wise_accounts.find_by(balance_id: "10000002")
    standard = @wise_item.wise_accounts.find_by(balance_id: "10000001")

    assert_equal 1, jar.raw_transactions_payload.size
    assert jar.raw_transactions_payload.any? { |a| a["type"] == "INTERBALANCE" }
    assert standard.raw_transactions_payload.any? { |a| a["type"] == "INTERBALANCE" }
  end

  test "routes BALANCE_CASHBACK only to JAR account" do
    savings = {
      "id" => "10000002",
      "amount" => { "value" => 1000.0, "currency" => "EUR" },
      "totalWorth" => { "value" => 1000.0, "currency" => "EUR" },
      "reservedAmount" => { "value" => 0.0, "currency" => "EUR" },
      "type" => "SAVINGS",
      "name" => "Jar"
    }
    cashback = build_cashback("57001")
    provider = FakeWiseProvider.new(savings_balances: [ savings ], activities: [ cashback ])

    WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    jar = @wise_item.wise_accounts.find_by(balance_id: "10000002")
    standard = @wise_item.wise_accounts.find_by(balance_id: "10000001")

    assert_equal 1, jar.raw_transactions_payload.size
    assert_empty standard.raw_transactions_payload.select { |a| a["type"] == "BALANCE_CASHBACK" }
  end

  # Returns failed result when balances fetch fails

  test "returns failed result when STANDARD balances fetch fails" do
    provider = FakeWiseProvider.new(raise_on: { get_balances: "unauthorized" })

    result = WiseItem::Importer.new(@wise_item, wise_provider: provider).import

    assert_not result[:success]
    assert_equal "Failed to fetch balances", result[:error]
  end

  private

    def build_transfer(id:, source_currency: "EUR", target_currency: "EUR", target_account: 9999)
      {
        "id" => id,
        "targetAccount" => target_account,
        "sourceCurrency" => source_currency,
        "targetCurrency" => target_currency,
        "sourceValue" => 100.0,
        "targetValue" => 100.0,
        "status" => "outgoing_payment_sent",
        "created" => 7.days.ago.strftime("%Y-%m-%d %H:%M:%S")
      }
    end

    def build_interbalance(title, resource_id:)
      {
        "id" => "interbalance_#{resource_id}",
        "type" => "INTERBALANCE",
        "resource" => { "type" => "BALANCE_TRANSACTION", "id" => resource_id },
        "title" => title,
        "primaryAmount" => "1,000 EUR",
        "status" => "COMPLETED",
        "createdOn" => 7.days.ago.iso8601
      }
    end

    def build_cashback(resource_id)
      {
        "id" => "cashback_#{resource_id}",
        "type" => "BALANCE_CASHBACK",
        "resource" => { "type" => "BALANCE_CASHBACK", "id" => resource_id },
        "title" => "<strong>Cashback</strong>",
        "primaryAmount" => "<positive>+ 1.12 EUR</positive>",
        "status" => "COMPLETED",
        "createdOn" => 3.days.ago.iso8601
      }
    end
end
