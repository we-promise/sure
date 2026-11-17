# frozen_string_literal: true

# Lifecycle contract for an account provider on the provider kit. Include it in a
# test case that defines `provider_item` (a persisted connection with at least
# one provider account), `other_provider_account` (a provider account that
# belongs to a different account provider in the same family),
# `selectable_accountable_type`, `api_accounts_for(account_ids)` (the
# provider's API payload listing accounts with those ids, each offered for
# that type) and `provider_api_error` (an error the provider's client raises
# for an API failure). It includes ProviderItemModelLifecycleTests.
module ProviderItemLifecycleTests
  extend ActiveSupport::Concern
  include ProviderItemModelLifecycleTests

  included do
    test "lifecycle: the account flow is the shared flow and keeps its old constants" do
      assert_operator account_flow_class, :<, ProviderItem::AccountFlow
      assert_same ProviderItem::AccountFlow::NoApiTokenError, account_flow_class::NoApiTokenError
      %i[AccountNotFoundError InvalidAccountNameError AccountAlreadyLinkedError NavigationResult LinkAccountsResult SetupResult SetupCompletion].each do |constant|
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

    test "lifecycle: setup imports the reported accounts and creates the ones given a supported type" do
      provider_item.class.any_instance.expects(:sync_later).once
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "setup-1", "setup-2", "setup-3" ]))
      unsupported_type = (Accountable::TYPES - "Provider::#{provider_item.provider_key.camelize}Adapter".constantize.supported_account_types).first

      assert_difference -> { provider_item.provider_accounts.count }, 3 do
        assert_nil account_flow.import_accounts_with_user_facing_error
      end
      imported = provider_item.provider_accounts.where(account_id: %w[setup-1 setup-2 setup-3]).index_by(&:account_id)
      assert_equal imported.values.map(&:id).sort, (account_flow.unlinked_provider_accounts.map(&:id) & imported.values.map(&:id)).sort

      result = assert_difference([ "Account.count", "AccountProvider.count" ], 1) do
        account_flow.complete_setup!(
          account_types: {
            imported["setup-1"].id.to_s => selectable_accountable_type,
            imported["setup-2"].id.to_s => "skip",
            imported["setup-3"].id.to_s => unsupported_type
          },
          account_subtypes: {}
        )
      end

      assert_kind_of ProviderItem::AccountFlow::SetupResult, result
      assert_equal [ imported["setup-1"].reload.account ], result.created_accounts
      assert_equal selectable_accountable_type, imported["setup-1"].account.accountable_type
      assert_equal 2, result.skipped_count
      assert_not_includes account_flow.unlinked_provider_accounts, imported["setup-1"]

      again = assert_no_difference([ "Account.count", "AccountProvider.count" ]) do
        account_flow.complete_setup!(account_types: { imported["setup-1"].id.to_s => selectable_accountable_type }, account_subtypes: {})
      end
      assert_equal [ 0, 0 ], [ again.created_count, again.failed_count ]
    end

    test "lifecycle: setup keeps the accounts it created when a later one raises" do
      provider_item.class.any_instance.expects(:sync_later).once
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "raise-1", "raise-2" ]))
      account_flow.import_accounts_with_user_facing_error
      first, second = provider_item.provider_accounts.where(account_id: %w[raise-1 raise-2]).order(:account_id).to_a
      provider_item.provider_accounts.klass.any_instance.stubs(:current_balance).returns(10).then.raises(RuntimeError, "unexpected")

      result = assert_difference([ "Account.count", "AccountProvider.count" ], 1) do
        account_flow.complete_setup!(
          account_types: { first.id.to_s => selectable_accountable_type, second.id.to_s => selectable_accountable_type },
          account_subtypes: {}
        )
      end

      assert_equal [ 1, 1 ], [ result.created_count, result.failed_count ]
      assert first.reload.account_provider.present?
      assert_nil second.reload.account_provider
    end

    test "lifecycle: setup leaves an imported account alone when the provider reports it unchanged" do
      account_flow_class.any_instance.stubs(:fetch_accounts).returns(api_accounts_for([ "unchanged-1" ]))
      account_flow.import_accounts_with_user_facing_error

      account_flow_class.any_instance.expects(:upsert_provider_account!).never
      assert_nil account_flow.import_accounts_with_user_facing_error
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
end
