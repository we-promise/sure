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

  test "family reset removes source tombstones and import records but no foreign enrollment" do
    Provider::Plaid.any_instance.stubs(:remove_item)
    Financekit::Processor.new(@item).apply!(financekit_payload)
    Family::FinancialDataReset.new(family: @family, dry_run: false, confirmed: true).call
    assert_not FinancekitItem.exists?(@item.id)
    assert_not FinancekitTransaction.where(financekit_account_id: @source.id).exists?
  end

  test "family sync does not manufacture a new Wallet fetch" do
    assert_empty @family.financekit_items.syncable
    assert_nil @item.last_imported_at
  end
end
