require "test_helper"

class YaxiAccountTest < ActiveSupport::TestCase
  setup do
    @item = YaxiItem.create!(family: families(:dylan_family), name: "Test YAXI")
    @yaxi_account = @item.yaxi_accounts.create!(
      external_id: Digest::SHA256.hexdigest("DE123\x1FEUR"),
      iban: "DE123",
      name: "Current account",
      currency: "EUR",
      account_type: "Current"
    )
    @account = @yaxi_account.ensure_linked_account!
  end

  test "creates the matching Sure account type" do
    assert_predicate @account, :depository?
    assert_equal "checking", @account.accountable.subtype
    assert_equal @yaxi_account, @account.account_providers.first.provider
  end

  test "imports YAXI amounts using Sure's transaction sign convention" do
    @yaxi_account.import_transactions!([
      {
        "bookingDate" => "2026-08-01",
        "status" => "Booked",
        "transactionId" => "purchase-1",
        "amount" => { "amount" => "-19.99", "currency" => "EUR" },
        "creditor" => { "name" => "Coffee Shop" },
        "remittanceInformation" => [ "Breakfast" ]
      },
      {
        "bookingDate" => "2026-08-02",
        "status" => "Pending",
        "transactionId" => "salary-1",
        "amount" => { "amount" => "1000.00", "currency" => "EUR" },
        "debtor" => { "name" => "Employer" }
      }
    ])

    purchase = @account.entries.find_by!(external_id: "yaxi_purchase-1")
    salary = @account.entries.find_by!(external_id: "yaxi_salary-1")

    assert_equal BigDecimal("19.99"), purchase.amount
    assert_equal "Coffee Shop", purchase.name
    assert_equal BigDecimal("-1000.00"), salary.amount
    assert salary.transaction.extra.dig("yaxi", "pending")
  end

  test "imports transaction batches" do
    @yaxi_account.import_transactions!([
      {
        "transactions" => [
          {
            "bookingDate" => "2026-08-01",
            "status" => "Booked",
            "transactionId" => "batch-1",
            "amount" => { "amount" => "-5.00", "currency" => "EUR" },
            "creditor" => { "name" => "Bakery" }
          }
        ]
      }
    ])

    assert_equal BigDecimal("5.00"), @account.entries.find_by!(external_id: "yaxi_batch-1").amount
  end

  test "skips and records pending transactions without a date" do
    assert_difference "DebugLogEntry.count", 1 do
      assert_no_difference "@account.entries.count" do
        @yaxi_account.import_transactions!([
          {
            "status" => "Pending",
            "amount" => { "amount" => "-10.00", "currency" => "EUR" },
            "creditor" => { "name" => "Pending merchant" }
          }
        ])
      end
    end

    log = DebugLogEntry.order(:created_at).last
    assert_equal "yaxi", log.provider_key
    assert_equal 1, log.metadata.fetch("skipped_count")
    assert_equal({ "Pending" => 1 }, log.metadata.fetch("statuses"))
  end


  test "does not treat repeated fallback references as unique transaction IDs" do
    @yaxi_account.import_transactions!([
      {
        "bookingDate" => "2026-08-03",
        "endToEndId" => "NOTPROVIDED",
        "amount" => { "amount" => "-10.00", "currency" => "EUR" },
        "creditor" => { "name" => "First merchant" }
      },
      {
        "bookingDate" => "2026-08-04",
        "endToEndId" => "NOTPROVIDED",
        "amount" => { "amount" => "-20.00", "currency" => "EUR" },
        "creditor" => { "name" => "Second merchant" }
      }
    ])

    assert_equal 2, @account.entries.where(source: "yaxi").count
    assert_equal 2, @account.entries.where(source: "yaxi").distinct.count(:external_id)
  end

  test "skips and records transactions with unparsable amounts" do
    assert_difference "DebugLogEntry.count", 1 do
      assert_no_difference "@account.entries.count" do
        @yaxi_account.import_transactions!([
          {
            "bookingDate" => "2026-08-05",
            "transactionId" => "invalid-amount",
            "amount" => { "amount" => "not-a-number", "currency" => "EUR" }
          }
        ])
      end
    end

    log = DebugLogEntry.order(:created_at).last
    assert_equal "Skipped YAXI transaction with an unparsable amount", log.message
    assert_equal "not-a-number", log.metadata.fetch("amount")
  end

  test "localizes fallback transaction names" do
    I18n.with_locale(:de) do
      @yaxi_account.import_transactions!([ {
        "bookingDate" => "2026-08-06",
        "transactionId" => "fallback-name",
        "amount" => { "amount" => "-5.00", "currency" => "EUR" }
      } ])
    end

    assert_equal "Ausgehende Überweisung", @account.entries.find_by!(external_id: "yaxi_fallback-name").name
  end
end
