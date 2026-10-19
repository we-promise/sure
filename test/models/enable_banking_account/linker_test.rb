require "test_helper"

class EnableBankingAccount::LinkerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @other_user = users(:family_member)
  end

  test "reuses the original account after deleting and recreating a consent" do
    old_item = create_item
    old_provider_account = create_provider_account(old_item, api_uid: "old-session-uid")
    native_account = link(old_provider_account)
    purchase = create_transaction(
      account: native_account,
      name: "Existing purchase",
      date: Date.new(2026, 1, 12),
      amount: 25,
      currency: "EUR",
      source: "enable_banking",
      external_id: "enable_banking_txn_existing_purchase",
      category: categories(:food_and_drink)
    )
    counterparty = create_native_account(name: "Counterparty")
    transfer = create_transfer(
      from_account: native_account,
      to_account: counterparty,
      amount: 75,
      date: Date.new(2026, 1, 13),
      currency: "EUR"
    )
    entry_ids = native_account.entries.order(:id).pluck(:id)
    transaction_ids = native_account.transactions.order(:id).pluck(:id)
    transfer_ids = [ transfer.id ]
    fingerprint = old_provider_account.reconnection_fingerprint

    old_item.destroy!

    new_item = create_item
    new_provider_account = create_provider_account(new_item, api_uid: "new-session-uid")
    assert_not_equal old_provider_account.account_id, new_provider_account.account_id

    assert_no_difference "Account.count" do
      assert_difference "AccountProvider.count", 1 do
        assert_equal native_account.id, link(new_provider_account).id
      end
    end

    native_account.reload
    assert_equal entry_ids, native_account.entries.order(:id).pluck(:id)
    assert_equal transaction_ids, native_account.transactions.order(:id).pluck(:id)
    assert_equal transfer_ids, Transfer.where(id: transfer.id).pluck(:id)
    assert_equal categories(:food_and_drink).id, purchase.reload.entryable.category_id
    assert_equal "enable_banking_txn_existing_purchase", purchase.reload.external_id
    assert_equal new_provider_account, AccountProvider.find_by!(account: native_account).provider
    assert_equal fingerprint, native_account.enable_banking_fingerprint
    assert_equal 1, Account.where(enable_banking_fingerprint: fingerprint).count
  end

  test "remembers the native account when the item explicitly unlinks its accounts" do
    old_item = create_item
    old_provider_account = create_provider_account(old_item, api_uid: "unlinked-session-uid")
    native_account = link(old_provider_account)
    fingerprint = old_provider_account.reconnection_fingerprint

    old_item.unlink_all!

    assert_nil old_provider_account.reload.account
    assert_equal fingerprint, native_account.reload.enable_banking_fingerprint

    new_provider_account = create_provider_account(create_item, api_uid: "reconnected-session-uid")
    assert_no_difference "Account.count" do
      assert_equal native_account.id, link(new_provider_account).id
    end
    assert_equal new_provider_account, AccountProvider.find_by!(account: native_account).provider
  end

  test "replaces the provider link when two active consents share an identity" do
    first_provider_account = create_provider_account(create_item, api_uid: "first-session-uid")
    native_account = link(first_provider_account)
    second_provider_account = create_provider_account(create_item, api_uid: "second-session-uid")
    fingerprint = first_provider_account.reconnection_fingerprint

    assert_no_difference "Account.count" do
      assert_no_difference "AccountProvider.count" do
        assert_equal native_account.id, link(second_provider_account).id
      end
    end

    assert_nil first_provider_account.reload.account
    assert_equal native_account.id, second_provider_account.reload.account.id
    assert_equal second_provider_account, AccountProvider.find_by!(account: native_account).provider
    assert_equal 1, Account.where(enable_banking_fingerprint: fingerprint).count
  end

  test "backfills a missing fingerprint from a unique legacy provider link" do
    old_provider_account = create_provider_account(create_item, api_uid: "legacy-linked-uid")
    native_account = link(old_provider_account)
    fingerprint = old_provider_account.reconnection_fingerprint
    native_account.update_column(:enable_banking_fingerprint, nil)
    new_provider_account = create_provider_account(create_item, api_uid: "new-consent-uid")

    assert_no_difference "Account.count" do
      assert_no_difference "AccountProvider.count" do
        assert_equal native_account.id, link(new_provider_account).id
      end
    end

    assert_equal fingerprint, native_account.reload.enable_banking_fingerprint
    assert_nil old_provider_account.reload.account
    assert_equal new_provider_account, AccountProvider.find_by!(account: native_account).provider
  end

  test "rejects an ambiguous identity across multiple legacy provider links" do
    old_provider_accounts = 2.times.map do |index|
      provider_account = create_provider_account(
        create_item,
        api_uid: "legacy-ambiguous-uid-#{index}"
      )
      native_account = Account.create_from_enable_banking_account(
        provider_account,
        "Depository",
        "checking",
        owner: @owner
      )
      AccountProvider.create!(account: native_account, provider: provider_account)
      native_account.update_column(:enable_banking_fingerprint, nil)
      [ provider_account, native_account ]
    end
    incoming_provider_account = create_provider_account(create_item, api_uid: "incoming-ambiguous-uid")
    account_count = Account.count
    provider_link_count = AccountProvider.count

    assert_raises ActiveRecord::RecordInvalid do
      link(incoming_provider_account)
    end

    assert_equal account_count, Account.count
    assert_equal provider_link_count, AccountProvider.count
    old_provider_accounts.each do |provider_account, native_account|
      assert_nil native_account.reload.enable_banking_fingerprint
      assert_equal provider_account, AccountProvider.find_by!(account: native_account).provider
    end
    assert_nil incoming_provider_account.reload.account
  end

  test "keeps same-IBAN currency accounts separate" do
    item = create_item
    currencies = %w[EUR CHF USD GBP]

    accounts = currencies.map do |currency|
      provider_account = create_provider_account(
        item,
        api_uid: "session-uid-#{currency}",
        currency: currency,
        fingerprint: "shared-iban-hash"
      )
      link(provider_account)
    end

    assert_equal 4, accounts.map(&:id).uniq.length
    assert_equal currencies.sort, accounts.map(&:currency).sort
    assert_equal 4, accounts.map(&:enable_banking_fingerprint).uniq.length
    assert_equal 4, Account.where(enable_banking_fingerprint: accounts.map(&:enable_banking_fingerprint)).count
  end

  test "does not reuse an account owned by another user without full control" do
    first_provider_account = create_provider_account(create_item, api_uid: "owner-session-uid")
    native_account = link(first_provider_account)
    second_provider_account = create_provider_account(create_item, api_uid: "member-session-uid")
    provider_link = AccountProvider.find_by!(account: native_account)
    account_count = Account.count

    assert_raises ActiveRecord::RecordInvalid do
      link(second_provider_account, user: @other_user)
    end

    assert_equal account_count, Account.count
    assert_equal provider_link.id, AccountProvider.find_by!(account: native_account).id
    assert_equal first_provider_account, provider_link.reload.provider
    assert_nil second_provider_account.reload.account

    native_account.account_shares.find_or_initialize_by(user: @other_user).update!(permission: "full_control")
    assert_equal native_account.id, link(second_provider_account, user: @other_user).id
  end

  test "is idempotent when setup is repeated for the same provider account" do
    provider_account = create_provider_account(create_item, api_uid: "repeat-session-uid")
    native_account = link(provider_account)

    assert_no_difference "Account.count" do
      assert_no_difference "AccountProvider.count" do
        assert_equal native_account.id, link(provider_account).id
      end
    end
  end

  test "rejects remembered accounts with an incompatible type subtype currency or deletion state" do
    scenarios = [
      { fingerprint: "type-conflict", account_type: "CreditCard", subtype: "credit_card" },
      { fingerprint: "subtype-conflict", subtype: "savings" },
      { fingerprint: "currency-conflict", prepare: ->(account) { account.update_column(:currency, "CHF") } },
      { fingerprint: "deletion-conflict", prepare: ->(account) { account.mark_for_deletion! } }
    ]

    scenarios.each do |scenario|
      original_provider_account = create_provider_account(create_item, api_uid: "old-#{scenario[:fingerprint]}",
        fingerprint: scenario[:fingerprint])
      native_account = link(original_provider_account)
      scenario[:prepare]&.call(native_account)
      incoming_provider_account = create_provider_account(create_item,
        api_uid: "new-#{scenario[:fingerprint]}", fingerprint: scenario[:fingerprint])
      provider_link = AccountProvider.find_by!(account: native_account)
      account_count = Account.count

      assert_raises ActiveRecord::RecordInvalid, scenario[:fingerprint] do
        link(incoming_provider_account, account_type: scenario.fetch(:account_type, "Depository"),
          subtype: scenario.fetch(:subtype, "checking"))
      end

      assert_equal account_count, Account.count
      assert_equal original_provider_account, provider_link.reload.provider
      assert_nil incoming_provider_account.reload.account
    end
  end

  test "does not fuzzy-reuse an account when the stable hash is missing" do
    old_provider_account = create_provider_account(create_item, api_uid: "legacy-session-uid", fingerprint: nil)
    old_account = link(old_provider_account)
    new_provider_account = create_provider_account(create_item, api_uid: "new-legacy-session-uid", fingerprint: nil)

    assert_nil old_account.reload.enable_banking_fingerprint
    assert_difference "AccountProvider.count", 1 do
      assert_difference "Account.count", 1 do
        @new_account = link(new_provider_account)
      end
    end

    assert_not_equal old_account.id, @new_account.id
    assert_equal old_account.name, @new_account.name
    assert_equal old_account.currency, @new_account.currency
  end

  test "reuses a disabled remembered account without restoring it" do
    old_item = create_item
    old_provider_account = create_provider_account(old_item, api_uid: "disabled-old-uid")
    native_account = link(old_provider_account)
    native_account.disable!
    native_account.update!(exclude_from_reports: true)
    disabled_at = native_account.reload.disabled_at

    old_item.destroy!
    new_provider_account = create_provider_account(create_item, api_uid: "disabled-new-uid")

    assert_equal native_account.id, link(new_provider_account).id
    native_account.reload
    assert native_account.disabled?
    assert_equal disabled_at, native_account.disabled_at
    assert native_account.exclude_from_reports?
  end

  private

    def create_item(name: "Enable Banking test", country_code: "IT", aspsp_name: "FinecoBank")
      EnableBankingItem.create!(
        family: @family,
        name: name,
        country_code: country_code,
        aspsp_name: aspsp_name,
        application_id: "test-app-id",
        client_certificate: "test-certificate"
      )
    end

    def create_provider_account(item, api_uid:, fingerprint: "stable-account-hash", currency: "EUR",
      iban: "IT60X0542811101000000123456")
      raw_payload = {
        "uid" => api_uid,
        "account_id" => { "iban" => iban },
        "currency" => currency,
        "cash_account_type" => "CACC"
      }
      raw_payload["identification_hash"] = fingerprint if fingerprint.present?

      item.enable_banking_accounts.create!(
        name: "Fineco Depository",
        uid: "provider-row-#{api_uid}",
        account_id: api_uid,
        currency: currency,
        current_balance: 100,
        account_type: "CACC",
        iban: iban,
        raw_payload: raw_payload
      )
    end

    def link(provider_account, user: @owner, account_type: "Depository", subtype: "checking")
      EnableBankingAccount::Linker.new(provider_account, user: user)
        .link!(account_type: account_type, subtype: subtype)
    end

    def create_native_account(name:)
      Account.create!(
        family: @family,
        owner: @owner,
        name: name,
        balance: 0,
        currency: "EUR",
        accountable: Depository.new(subtype: "checking")
      )
    end
end
