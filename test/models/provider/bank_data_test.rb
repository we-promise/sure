require "minitest/autorun"
require_relative "../../../app/models/provider"
require_relative "../../../app/models/provider/bank_data"
require_relative "../../../app/models/provider/bank_data/definition"
require_relative "../../../app/models/provider/bank_data/adapter"
require_relative "../../../app/models/provider/bank_data/record"
require_relative "../../../app/models/provider/bank_data/page"

class Provider::BankDataTest < Minitest::Test
  def test_legacy_namespace_preserves_contract_class_identity
    assert_same Provider::AccountData, Provider::BankData
    %i[Definition Adapter Page Record Error NotImplementedError UnsupportedCapability InvalidResponse StaleWriter IncompletePage].each do |name|
      assert_same Provider::AccountData.const_get(name), Provider::BankData.const_get(name)
    end
  end

  def test_old_and_new_record_names_share_the_source_independent_value_contract
    assert_same Ingestion::Record, Provider::AccountData::Record
    assert_same Ingestion::Record, Provider::BankData::Record

    value = Ingestion::Record.transaction(
      external_id: "legacy-id", name: "Coffee", currency: "USD",
      date: Date.new(2026, 9, 14), amount: BigDecimal("4.25"), pending: false
    )
    page = Provider::BankData::Page.new(records: [ value ], complete: true)

    assert_same value, page.records.first
    assert_instance_of Provider::AccountData::Page, page
  end
end
