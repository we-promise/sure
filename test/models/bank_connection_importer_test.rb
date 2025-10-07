require "test_helper"

class BankConnectionImporterTest < ActiveSupport::TestCase
  class StubProvider
    def initialize(*); end
    def verify_credentials!; true; end
    def list_accounts
      [ { id: "acc1", name: "Primary", currency: "USD", current_balance: 100.0, available_balance: 100.0 } ]
    end
    def list_transactions(account_id:, start_date:, end_date:)
      [ { id: "tx1", amount: 5.0, date: start_date.to_s, description: "Test" } ]
    end
  end

  class StubMapper < Provider::Banks::Mapper
    def normalize_account(payload)
      data = payload.symbolize_keys
      {
        provider_account_id: data[:id],
        name: data[:name],
        currency: data[:currency],
        current_balance: BigDecimal(data[:current_balance].to_s),
        available_balance: BigDecimal(data[:available_balance].to_s)
      }
    end

    def normalize_transaction(payload, currency:)
      data = payload.symbolize_keys
      {
        external_id: "stub_#{data[:id]}",
        posted_at: Date.parse(data[:date]),
        amount: BigDecimal(data[:amount].to_s),
        description: data[:description]
      }
    end
  end

  setup do
    @family = families(:dylan_family)
  end

  test "imports accounts and transactions via provider" do
    # Stub registry to return our stub classes
    Provider::Banks::Registry.stubs(:get_instance).returns(StubProvider.new)
    Provider::Banks::Registry.stubs(:get_mapper).returns(StubMapper.new)

    conn = @family.bank_connections.create!(name: "Test", provider: :test, credentials: { api_key: "x" }.to_json)

    assert_difference -> { BankExternalAccount.count }, +1 do
      conn.import_latest_bank_data
    end

    ext = conn.bank_external_accounts.first
    assert_equal "acc1", ext.provider_account_id
    assert ext.raw_transactions_payload.present?
  end
end
