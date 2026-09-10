require "test_helper"
require_relative "../../support/financekit_test_helper"

class Financekit::LifecycleTest < ActiveSupport::TestCase
  include FinancekitTestHelper
  setup { financekit_setup }

  test "another provider cannot attach to a FinanceKit canonical account" do
    assert_raises(ActiveRecord::RecordInvalid) do
      @source.account.account_providers.create!(provider: plaid_accounts(:one))
    end
  end

  test "a source account cannot link to another family" do
    other = users(:empty)
    account = other.family.accounts.create!(owner: other, name: "Other household", currency: "USD", balance: 25,
      accountable: Depository.new(subtype: "checking"))
    new_source = SecureRandom.uuid
    @item.update!(consent: @item.consent.merge("source_ids" => [ @source_id, new_source ]))
    assert_raises(ActiveRecord::RecordNotFound) do
      FinancekitAccount.map!(@item, new_source,
        @mapping_input.except("booked_balance", "observed_at").merge("action" => "link", "account_id" => account.id))
    end
  end

  test "selection changes fence queued work and reject removed accounts" do
    envelope = financekit_envelope
    batch = FinancekitBatch.accept!(@item, envelope)
    @item.replace_device!({ "expected_generation" => 1, "device_public_key" => @device_jwk,
      "consent" => @enrollment["consent"].merge("source_ids" => [ SecureRandom.uuid ]),
      "continuity" => "same_source_and_transaction_ids" })
    assert_equal "revoked", batch.reload.status
    assert_equal 1, @item.financekit_accounts.count
    assert_equal 409, assert_raises(Financekit::Error) { FinancekitBatch.accept!(@item, financekit_envelope) }.status
  end

  test "export retains source identity without encryption or device credentials" do
    FinancekitBatch.accept!(@item, financekit_envelope)
    Financekit::Processor.new(@item).apply_next!
    data = Financekit::Export.for_family(@family)
    assert_equal @source_id, data.first.fetch("accounts").first.fetch("source_id")
    json = JSON.generate(data)
    assert_not_includes json, "device_public_key"
    assert_not_includes json, "envelope"
    assert_not_includes json, "PRIVATE KEY"
  end

  test "family reset removes source tombstones and inbox but no foreign enrollment" do
    Provider::Plaid.any_instance.stubs(:remove_item)
    FinancekitBatch.accept!(@item, financekit_envelope)
    Financekit::Processor.new(@item).apply_next!
    Family::FinancialDataReset.new(family: @family, dry_run: false, confirmed: true).call
    assert_not FinancekitItem.exists?(@item.id)
    assert_not FinancekitTransaction.where(financekit_account_id: @source.id).exists?
  end

  test "family sync does not manufacture a new Wallet fetch" do
    assert_empty @family.financekit_items.syncable
    assert_nil @item.last_imported_at
  end
end
