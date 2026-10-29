require "test_helper"

class PlaidItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @plaid_item = plaid_items(:one)
  end

  # A Plaid rate change is dated to the sync. The syncer reads the clock once
  # and hands that date to the processing phase.
  test "the processing phase is given the sync's date" do
    dated = nil

    travel_to Time.zone.local(2026, 1, 15, 12, 0, 0) do
      @plaid_item.stubs(:import_latest_plaid_data)
      @plaid_item.stubs(:schedule_account_syncs)
      @plaid_item.expects(:process_accounts).with { |**kwargs| dated = kwargs[:as_of] }

      PlaidItem::Syncer.new(@plaid_item).perform_sync(stub_sync)
    end

    assert_equal Date.new(2026, 1, 15), dated
  end

  # A background job runs in UTC. At 06:00 on 16 Jan in Sydney it is still the
  # 15th in UTC, and a rate change dated the 15th would be charged from a period
  # before the user saw it.
  test "the sync's date is the family's date, not the job's" do
    @plaid_item.family.update!(timezone: "Australia/Sydney")
    dated = nil

    travel_to Time.utc(2026, 1, 15, 19, 0, 0) do
      @plaid_item.stubs(:import_latest_plaid_data)
      @plaid_item.stubs(:schedule_account_syncs)
      @plaid_item.expects(:process_accounts).with { |**kwargs| dated = kwargs[:as_of] }

      PlaidItem::Syncer.new(@plaid_item).perform_sync(stub_sync)
    end

    assert_equal Date.new(2026, 1, 16), dated
  end

  test "process_accounts hands its date to every account's processor" do
    date = Date.new(2026, 1, 15)
    processor = mock("processor")
    processor.stubs(:process)

    assert_not_empty @plaid_item.plaid_accounts
    @plaid_item.plaid_accounts.each do |plaid_account|
      PlaidAccount::Processor.expects(:new).with(plaid_account, as_of: date).returns(processor)
    end

    @plaid_item.process_accounts(as_of: date)
  end

  # The chain end to end: the importer swallows ITEM_LOGIN_REQUIRED, the
  # processing phase still runs, and the stored liabilities payload is last
  # sync's. Its rate must not become a change dated today.
  test "a sync whose import needed a fresh login dates no rate change" do
    plaid_account = plaid_accounts(:one)
    plaid_account.update!(plaid_type: "loan", plaid_subtype: "mortgage",
                          raw_liabilities_payload: { mortgage: { interest_rate: { type: "variable", percentage: 5.2 } } })
    plaid_account.current_account.update!(accountable: Loan.new(interest_rate: 4.5, rate_type: "variable", start_date: Date.new(2020, 1, 1)))
    loan = plaid_account.current_account.loan

    provider = mock("Provider::Plaid")
    provider.stubs(:get_item).raises(Plaid::ApiError.new(code: 400, response_body: { "error_code" => "ITEM_LOGIN_REQUIRED" }.to_json))
    @plaid_item.stubs(:plaid_provider).returns(provider)
    @plaid_item.stubs(:schedule_account_syncs)

    PlaidItem::Syncer.new(@plaid_item).perform_sync(stub_sync)

    assert_predicate @plaid_item.reload, :requires_update?
    loan.reload
    assert_empty loan.variable_rate_schedule || {}, "a stale payload's rate was dated as a change"
    assert_equal 4.5, loan.interest_rate.to_f
  end

  # Plaid can stop returning an account, closed at the bank say. Its stored
  # payload is then an earlier sync's, and must not be dated as a change.
  test "an account Plaid leaves out of the sync dates no rate change" do
    plaid_account = plaid_accounts(:one)
    plaid_account.update!(plaid_type: "loan", plaid_subtype: "mortgage",
                          raw_liabilities_payload: { mortgage: { interest_rate: { type: "variable", percentage: 5.2 } } })
    plaid_account.current_account.update!(accountable: Loan.new(interest_rate: 4.5, rate_type: "variable", start_date: Date.new(2020, 1, 1)))
    loan = plaid_account.current_account.loan

    provider = mock("Provider::Plaid")
    provider.stubs(:get_item).returns(OpenStruct.new(item: OpenStruct.new(institution_id: "ins_1")))
    provider.stubs(:get_institution).returns(OpenStruct.new(institution: OpenStruct.new))
    @plaid_item.stubs(:plaid_provider).returns(provider)
    @plaid_item.stubs(:upsert_plaid_snapshot!)
    @plaid_item.stubs(:upsert_plaid_institution_snapshot!)
    @plaid_item.stubs(:schedule_account_syncs)
    PlaidItem::AccountsSnapshot.any_instance.stubs(:accounts).returns([])
    PlaidItem::AccountsSnapshot.any_instance.stubs(:transactions_cursor).returns(nil)

    PlaidItem::Syncer.new(@plaid_item).perform_sync(stub_sync)

    loan.reload
    assert_empty loan.variable_rate_schedule || {}, "a payload Plaid did not send this sync was dated as a change"
    assert_equal 4.5, loan.interest_rate.to_f
    assert_equal({}, plaid_account.reload.raw_liabilities_payload)
  end

  private
    def stub_sync
      sync = mock("sync")
      sync.stubs(:respond_to?).returns(true)
      sync.stubs(:sync_stats).returns({})
      sync.stubs(:created_at).returns(Time.current)
      sync.stubs(:window_start_date).returns(nil)
      sync.stubs(:window_end_date).returns(nil)
      sync.stubs(:update!)
      sync
    end
end
