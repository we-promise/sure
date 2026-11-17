# frozen_string_literal: true

# Lifecycle contract for an account provider on the provider kit. Include it in a
# test case that defines `provider_item` (a persisted connection with at least
# one provider account), `other_provider_account` (a provider account that
# belongs to a different account provider in the same family),
# `selectable_accountable_type`, `api_accounts_for(account_ids)` (the
# provider's API payload listing accounts with those ids, each offered for
# that type) and `provider_api_error` (an error the provider's client raises
# for an API failure).
module ProviderItemLifecycleTests
  extend ActiveSupport::Concern

  included do
    test "lifecycle: the connection is a provider item on its own table" do
      assert_kind_of ProviderItem, provider_item
      assert_kind_of ProviderAccount, provider_account
      assert_equal "#{provider_item.provider_key}_items", provider_item.class.table_name
      assert_includes Family::Syncer.syncable_item_associations, :"#{provider_item.provider_key}_items"
    end

    test "lifecycle: a sync runs the shared syncer and records setup counts" do
      provider_item.class.any_instance.stubs(:"import_latest_#{provider_item.provider_key}_data").returns(success: true)
      expected_total = provider_item.provider_accounts.count

      sync = Sync.create!(syncable: provider_item)
      sync.perform

      assert sync.reload.completed?, "expected the sync to complete, was #{sync.status}"
      assert_equal provider_item.class.name, sync.syncable_type
      assert_equal expected_total, sync.sync_stats["total_accounts"]
      assert_equal expected_total, sync.sync_stats["unlinked_accounts"]
    end

    test "lifecycle: unlinking removes the connection's links and detaches their holdings" do
      account, link = link_provider_account(provider_account)
      holding = create_holding(account, link)
      other_account, other_link = link_provider_account(other_provider_account)

      assert_equal provider_account.class.name, link.provider_type

      results = provider_item.unlink_all!

      assert_not AccountProvider.exists?(link.id)
      assert_nil holding.reload.account_provider_id
      assert Account.exists?(account.id)
      assert_includes results.find { |result| result[:provider_account_id] == provider_account.id }[:provider_link_ids], link.id
      assert AccountProvider.exists?(other_link.id), "another provider's link must survive"
      assert_equal other_account, other_link.reload.account
    end

    test "lifecycle: a dry run reports links without removing them" do
      _account, link = link_provider_account(provider_account)

      results = provider_item.unlink_all!(dry_run: true)

      assert AccountProvider.exists?(link.id)
      assert_includes results.find { |result| result[:provider_account_id] == provider_account.id }[:provider_link_ids], link.id
    end

    test "lifecycle: destroying the connection removes its provider accounts and their links" do
      _account, link = link_provider_account(provider_account)
      provider_account_class = provider_item.provider_accounts.klass
      provider_account_ids = provider_item.provider_accounts.ids

      provider_item.destroy!

      assert_not provider_account_class.exists?(id: provider_account_ids)
      assert_not AccountProvider.exists?(link.id)
    end

    test "lifecycle: the account flow is the shared flow and keeps its old constants" do
      assert_operator account_flow_class, :<, ProviderItem::AccountFlow
      assert_same ProviderItem::AccountFlow::NoApiTokenError, account_flow_class::NoApiTokenError
      %i[AccountNotFoundError InvalidAccountNameError AccountAlreadyLinkedError NavigationResult LinkAccountsResult].each do |constant|
        assert_same ProviderItem::AccountFlow.const_get(constant), account_flow_class.const_get(constant)
      end
      assert_equal provider_item.class, account_flow_class.item_class
    end

    test "lifecycle: selection offers the connection's accounts that are not linked yet" do
      linked_id = provider_account.account_id.to_s
      free_id = "#{linked_id}-free"
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ linked_id, free_id ]))

      with_memory_cache do
        assert_equal [ linked_id, free_id ].sort, offered_account_ids.sort
      end
      link_provider_account(provider_account)

      with_memory_cache do
        result = account_flow.select_accounts_result(accountable_type: selectable_accountable_type)
        assert result.success?
        assert_equal provider_item, result.item
        assert_equal [ free_id ], offered_account_ids
      end
    end

    test "lifecycle: selection offers nothing for a type the provider does not support" do
      unsupported_type = unsupported_accountable_type
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "any-account" ]))

      with_memory_cache do
        assert_equal [ "any-account" ], offered_account_ids
        assert_empty account_flow.select_accounts_result(accountable_type: unsupported_type).available_accounts
      end
    end

    test "lifecycle: a provider API error reaches the flow as an api_error" do
      account_flow_class.any_instance.stubs(:fetch_accounts).raises(provider_api_error)

      with_memory_cache do
        assert_equal [ "api_error", provider_api_error.message ], account_flow.preload_payload.values_at(:error, :error_message)

        result = account_flow.select_accounts_result(accountable_type: selectable_accountable_type)
        assert_equal [ :api_error, provider_api_error.message ], [ result.status, result.message ]
        assert result.provider_error?
      end
    end

    test "lifecycle: each connection caches its own accounts under the provider's key" do
      second_item = provider_item.dup.tap { |item| item.save!(validate: false) }
      first_key = account_flow_class.cache_key(provider_item.family, provider_item)

      assert first_key.start_with?("#{provider_item.provider_key}_accounts_")
      refute_equal first_key, account_flow_class.cache_key(provider_item.family, second_item)

      with_memory_cache do
        account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "only-on-the-first" ]))
        assert account_flow.preload_payload[:has_accounts]

        account_flow_class.any_instance.stubs(:fetch_accounts).returns([])
        assert_equal false, account_flow_class.new(family: provider_item.family, item: second_item).preload_payload[:has_accounts]
      end
    end

    test "lifecycle: linking new accounts creates one linked account per selected provider account" do
      provider_item.class.any_instance.expects(:sync_later).once
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "linked-new-1" ]))

      with_memory_cache do
        navigation = assert_difference([ "Account.count", "AccountProvider.count" ], 1) do
          account_flow.link_new_accounts_result(account_ids: [ "linked-new-1" ], accountable_type: selectable_accountable_type)
        end
        assert_equal I18n.t("#{provider_item.provider_key}_items.link_accounts.success", count: 1), navigation.message
        provider_account = provider_item.provider_accounts.find_by!(account_id: "linked-new-1")
        assert_equal selectable_accountable_type, provider_account.account.accountable_type

        result = assert_no_difference([ "Account.count", "AccountProvider.count" ]) do
          account_flow.link_new_accounts!(account_ids: [ "linked-new-1" ], accountable_type: selectable_accountable_type)
        end
        assert_kind_of ProviderItem::AccountFlow::LinkAccountsResult, result
        assert_equal 1, result.already_linked_count
      end
    end

    test "lifecycle: linking skips an account the provider cannot name" do
      provider_item.class.any_instance.expects(:sync_later).never
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "unnamed-1" ]))
      provider_item.provider_accounts.klass.stubs(:name_for).returns("")

      with_memory_cache do
        result = assert_no_difference([ "Account.count", "AccountProvider.count" ]) do
          account_flow.link_new_accounts!(account_ids: [ "unnamed-1" ], accountable_type: selectable_accountable_type)
        end
        assert_equal [ "unnamed-1" ], result.invalid_account_ids
      end
    end

    test "lifecycle: linking an existing account attaches it once" do
      provider_item.class.any_instance.expects(:sync_later).once
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "linked-existing-1" ]))
      account = provider_item.family.accounts.create!(name: "Existing", balance: 0, currency: "USD", accountable: Depository.new)

      with_memory_cache do
        navigation = assert_difference("AccountProvider.count", 1) do
          account_flow.link_existing_account_result(account: account, provider_account_id: "linked-existing-1")
        end
        # The text names the provider, so a flow reading another provider's scope fails here.
        assert_equal I18n.t("#{provider_item.provider_key}_items.link_existing_account.success", account_name: "Existing"), navigation.message
        provider_account = provider_item.provider_accounts.find_by!(account_id: "linked-existing-1")
        assert_equal account, provider_account.reload.account
        assert_equal provider_account.class.name, provider_account.account_provider.provider_type

        other = provider_item.family.accounts.create!(name: "Other", balance: 0, currency: "USD", accountable: Depository.new)
        assert_raises(ProviderItem::AccountFlow::AccountAlreadyLinkedError) do
          account_flow.link_existing_account!(account: other, provider_account_id: "linked-existing-1")
        end
      end
    end

    test "lifecycle: linking an existing account refuses one already linked elsewhere" do
      provider_item.class.any_instance.expects(:sync_later).once
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "taken-1", "free-1" ]))
      first = provider_item.family.accounts.create!(name: "First", balance: 0, currency: "USD", accountable: Depository.new)
      second = provider_item.family.accounts.create!(name: "Second", balance: 0, currency: "USD", accountable: Depository.new)

      with_memory_cache do
        account_flow.link_existing_account!(account: first, provider_account_id: "taken-1")

        navigation = assert_no_difference("AccountProvider.count") do
          account_flow.link_existing_account_result(account: first, provider_account_id: "free-1")
        end
        assert_equal I18n.t("#{provider_item.provider_key}_items.link_existing_account.account_already_linked"), navigation.message

        navigation = assert_no_difference("AccountProvider.count") do
          account_flow.link_existing_account_result(account: second, provider_account_id: "taken-1")
        end
        assert_equal I18n.t("#{provider_item.provider_key}_items.link_existing_account.provider_account_already_linked"), navigation.message
      end
    end

    test "lifecycle: an existing account of a type the provider does not support is neither offered nor linked" do
      provider_item.class.any_instance.expects(:sync_later).never
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "unsupported-1" ]))
      account = provider_item.family.accounts.create!(name: "Unsupported", balance: 0, currency: "USD", accountable: unsupported_accountable_type.constantize.new)
      invalid_type = I18n.t("#{provider_item.provider_key}_items.link_accounts.invalid_account_type")

      with_memory_cache do
        result = account_flow.select_existing_account_result(account: account)
        assert_equal [ :empty, invalid_type ], [ result.status, result.message ]

        navigation = assert_no_difference("AccountProvider.count") do
          account_flow.link_existing_account_result(account: account, provider_account_id: "unsupported-1")
        end
        assert_equal invalid_type, navigation.message
      end
    end
  end

  private
    def account_flow_class
      provider_item.class::AccountFlow
    end

    def account_flow
      account_flow_class.new(family: provider_item.family, item: provider_item)
    end

    def unsupported_accountable_type
      (Accountable::TYPES - "Provider::#{provider_item.provider_key.camelize}Adapter".constantize.supported_account_types).first
    end

    def offered_account_ids
      account_flow.select_accounts_result(accountable_type: selectable_accountable_type)
                  .available_accounts.map { |account| account.with_indifferent_access[:id].to_s }
    end

    def with_memory_cache
      original = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      yield
    ensure
      Rails.cache = original
    end

    def provider_account
      provider_item.provider_accounts.first
    end

    def link_provider_account(record)
      account = provider_item.family.accounts.create!(name: "Linked #{record.class.name}", balance: 0, currency: "USD", accountable: Investment.new)
      [ account, AccountProvider.create!(account: account, provider: record) ]
    end

    def create_holding(account, link)
      account.holdings.create!(
        security: securities(:aapl), date: Date.current, qty: 1, price: 10, amount: 10,
        currency: "USD", account_provider: link
      )
    end
end
