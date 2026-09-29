require "test_helper"

class SimplefinEntry::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @simplefin_item = SimplefinItem.create!(
      family: @family,
      name: "Test SimpleFin Bank",
      access_url: "https://example.com/access_token"
    )
    @simplefin_account = SimplefinAccount.create!(
      simplefin_item: @simplefin_item,
      name: "SF Checking",
      account_id: "sf_acc_1",
      account_type: "checking",
      currency: "USD",
      current_balance: 1000,
      available_balance: 1000,
      account: @account
    )
  end

  test "persists extra metadata (raw payee/memo/description and provider extra)" do
    tx = {
      id: "tx_1",
      amount: "-12.34",
      currency: "USD",
      payee: "Pizza Hut",
      description: "Order #1234",
      memo: "Carryout",
      posted: Date.current.to_s,
      transacted_at: (Date.current - 1).to_s,
      extra: { category: "restaurants", check_number: nil }
    }

    assert_difference "@account.entries.count", 1 do
      SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process
    end

    entry = @account.entries.find_by!(external_id: "simplefin_tx_1", source: "simplefin")
    extra = entry.transaction.extra

    assert_equal "Pizza Hut - Order #1234", entry.name
    assert_equal "USD", entry.currency

    # Check extra payload structure
    assert extra.is_a?(Hash), "extra should be a Hash"
    assert extra["simplefin"].is_a?(Hash), "extra.simplefin should be a Hash"
    sf = extra["simplefin"]
    assert_equal "Pizza Hut", sf["payee"]
    assert_equal "Carryout", sf["memo"]
    assert_equal "Order #1234", sf["description"]
    assert_equal({ "category" => "restaurants", "check_number" => nil }, sf["extra"])
  end
  test "does not flag pending when posted is nil but provider pending flag not set" do
    # Previously we inferred pending from missing posted date, but this was too aggressive -
    # some providers don't supply posted dates even for settled transactions
    tx = {
      id: "tx_pending_1",
      amount: "-20.00",
      currency: "USD",
      payee: "Coffee Shop",
      description: "Latte",
      memo: "Morning run",
      posted: nil,
      transacted_at: (Date.current - 3).to_s
    }

    SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process

    entry = @account.entries.find_by!(external_id: "simplefin_tx_pending_1", source: "simplefin")
    sf = entry.transaction.extra.fetch("simplefin")

    assert_equal false, sf["pending"], "expected pending flag to be false when provider doesn't explicitly set pending"
  end

  test "captures FX metadata when tx currency differs from account currency" do
    # Account is USD from setup; use EUR for tx
    t_date = (Date.current - 5)
    p_date = Date.current

    tx = {
      id: "tx_fx_1",
      amount: "-42.00",
      currency: "EUR",
      payee: "Boulangerie",
      description: "Croissant",
      posted: p_date.to_s,
      transacted_at: t_date.to_s
    }

    SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process

    entry = @account.entries.find_by!(external_id: "simplefin_tx_fx_1", source: "simplefin")
    sf = entry.transaction.extra.fetch("simplefin")

    assert_equal "EUR", sf["fx_from"]
    assert_equal t_date.to_s, sf["fx_date"], "fx_date should prefer transacted_at"
  end
  test "flags pending when provider pending flag is true (even if posted provided)" do
    tx = {
      id: "tx_pending_flag_1",
      amount: "-9.99",
      currency: "USD",
      payee: "Test Store",
      description: "Auth",
      memo: "",
      posted: Date.current.to_s, # provider says pending=true should still flag
      transacted_at: (Date.current - 1).to_s,
      pending: true
    }

    SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process

    entry = @account.entries.find_by!(external_id: "simplefin_tx_pending_flag_1", source: "simplefin")
    sf = entry.transaction.extra.fetch("simplefin")
    assert_equal true, sf["pending"], "expected pending flag to be true when provider sends pending=true"
  end

  test "posted==0 treated as missing, entry uses transacted_at date and flags pending" do
    # Simulate provider sending epoch-like zeros for posted and an integer transacted_at
    t_epoch = (Date.current - 2).to_time.to_i
    tx = {
      id: "tx_pending_zero_posted_1",
      amount: "-6.48",
      currency: "USD",
      payee: "Dunkin'",
      description: "DUNKIN #358863",
      memo: "",
      posted: 0,
      transacted_at: t_epoch,
      pending: true
    }

    SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process

    entry = @account.entries.find_by!(external_id: "simplefin_tx_pending_zero_posted_1", source: "simplefin")
    # For depository accounts, processor prefers posted, then transacted; posted==0 should be treated as missing
    assert_equal Time.at(t_epoch).utc.to_date, entry.date, "expected entry.date to use transacted_at when posted==0"
    sf = entry.transaction.extra.fetch("simplefin")
    assert_equal true, sf["pending"], "expected pending flag to be true when posted==0 and/or pending=true"
  end

  test "skips pending transactions when pending inclusion is disabled" do
    Setting.stubs(:syncs_include_pending).returns(false)

    tx = {
      id: "tx_pending_disabled_1",
      amount: "-30.00",
      currency: "USD",
      payee: "Test Store",
      description: "Auth hold",
      posted: Date.current.to_s,
      transacted_at: (Date.current - 1).to_s,
      pending: true
    }

    # Clear the env var so this only exercises the Setting fallback branch of pending_enabled?
    with_env_overrides SIMPLEFIN_INCLUDE_PENDING: nil do
      assert_no_difference "@account.entries.count" do
        SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process
      end
    end
  end

  test "still imports posted transactions when pending inclusion is disabled" do
    Setting.stubs(:syncs_include_pending).returns(false)

    tx = {
      id: "tx_posted_disabled_1",
      amount: "-30.00",
      currency: "USD",
      payee: "Test Store",
      description: "Settled",
      posted: Date.current.to_s,
      transacted_at: (Date.current - 1).to_s,
      pending: false
    }

    with_env_overrides SIMPLEFIN_INCLUDE_PENDING: nil do
      assert_difference "@account.entries.count", 1 do
        SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process
      end
    end
  end

  test "SIMPLEFIN_INCLUDE_PENDING env var takes precedence over Setting" do
    # Setting says "skip pending", but the env var (mirrored via the boot-time config it
    # populates) says "include pending" - env var must win, matching
    # SimplefinItem::Importer#fetch_accounts_data's effective_pending resolution.
    Setting.stubs(:syncs_include_pending).returns(false)
    Rails.configuration.x.simplefin.stubs(:include_pending).returns(true)

    tx = {
      id: "tx_pending_env_override_1",
      amount: "-30.00",
      currency: "USD",
      payee: "Test Store",
      description: "Auth hold",
      posted: Date.current.to_s,
      transacted_at: (Date.current - 1).to_s,
      pending: true
    }

    with_env_overrides SIMPLEFIN_INCLUDE_PENDING: "1" do
      assert_difference "@account.entries.count", 1 do
        SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process
      end
    end
  end

  test "SIMPLEFIN_INCLUDE_PENDING env var disabling pending takes precedence over a permissive Setting" do
    # Mirror of the test above: this is the actual real-world guard scenario the PR
    # fixes - a self-hoster sets SIMPLEFIN_INCLUDE_PENDING=0 while the Setting (UI
    # toggle) still says "include pending". The env var must win and skip the row.
    Setting.stubs(:syncs_include_pending).returns(true)
    Rails.configuration.x.simplefin.stubs(:include_pending).returns(false)

    tx = {
      id: "tx_pending_env_disable_1",
      amount: "-30.00",
      currency: "USD",
      payee: "Test Store",
      description: "Auth hold",
      posted: Date.current.to_s,
      transacted_at: (Date.current - 1).to_s,
      pending: true
    }

    with_env_overrides SIMPLEFIN_INCLUDE_PENDING: "0" do
      assert_no_difference "@account.entries.count" do
        SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process
      end
    end
  end

  test "infers pending when posted is explicitly 0 and transacted_at present (no explicit pending flag)" do
    # Some SimpleFIN banks indicate pending by sending posted=0 + transacted_at, without pending flag
    t_epoch = (Date.current - 1).to_time.to_i
    tx = {
      id: "tx_inferred_pending_1",
      amount: "-15.00",
      currency: "USD",
      payee: "Gas Station",
      description: "Fuel",
      memo: "",
      posted: 0,
      transacted_at: t_epoch
      # Note: NO pending flag set
    }

    SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process

    entry = @account.entries.find_by!(external_id: "simplefin_tx_inferred_pending_1", source: "simplefin")
    sf = entry.transaction.extra.fetch("simplefin")
    assert_equal true, sf["pending"], "expected pending to be inferred from posted=0 + transacted_at present"
  end

  test "does not treat a non-numeric posted value as epoch-zero pending" do
    # Regression: `posted_val.to_i.zero?` would also match malformed strings like
    # "unavailable" (String#to_i coerces non-numeric input to 0), wrongly flagging a
    # settled transaction as pending. Only literal 0 / "0" should count as epoch-zero.
    tx = {
      id: "tx_malformed_posted_1",
      amount: "-11.00",
      currency: "USD",
      payee: "Test Store",
      description: "Settled",
      memo: "",
      posted: "unavailable",
      transacted_at: (Date.current - 1).to_s
      # Note: NO pending flag set
    }

    SimplefinEntry::Processor.new(tx, simplefin_account: @simplefin_account).process

    entry = @account.entries.find_by!(external_id: "simplefin_tx_malformed_posted_1", source: "simplefin")
    sf = entry.transaction.extra.fetch("simplefin")
    assert_equal false, sf["pending"], "expected a non-numeric posted value to not be inferred as pending"
  end
end
