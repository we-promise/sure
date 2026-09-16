require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class Account::SourcePolicyTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  test "source handover keeps immutable revisions and one current authority" do
    with_provider_encryption do
      account = accounts(:depository)
      first = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection))
      second = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection(provider_key: "plaid")))
      original = Account::SourcePolicy.select!(account: account, account_provider: first, resource: "transactions")
      selected = Account::SourcePolicy.select!(account: account, account_provider: second, resource: "transactions")

      assert_not original.reload.active?
      assert_equal first.id, original.account_provider_id
      assert_equal 2, selected.revision
      assert_equal [ selected.id ], account.source_policies.active.where(resource: "transactions").pluck(:id)
      assert_no_difference "Account::SourcePolicy.count" do
        assert_equal selected, Account::SourcePolicy.select!(account: account, account_provider: second, resource: "transactions")
      end
    end
  end

  test "source selection rejects another account without changing the original policy" do
    with_provider_encryption do
      account = accounts(:depository)
      other_account = accounts(:investment)
      external = create_external_account(create_provider_connection)
      link = AccountProvider.create!(account: other_account, external_account: external)

      assert_no_difference "Account::SourcePolicy.count" do
        assert_raises(ArgumentError) { Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances") }
      end
    end
  end

  test "native shared account links supply presentation and sync through the common adapter" do
    with_provider_encryption do
      account = accounts(:depository)
      external = create_external_account(create_provider_connection)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select!(account: account, account_provider: link, resource: "balances")

      assert_instance_of Provider::ExternalAccountAdapter, account.provider
      assert_equal "up", account.provider_name
      assert_equal external.provider_connection, account.provider.item
      assert account.supports_category_matcher?
    end
  end

  test "banking and investment cash feeds cannot select different authorities" do
    with_provider_encryption do
      account = accounts(:investment)
      first = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection))
      second = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection(provider_key: "plaid")))
      Account::SourcePolicy.select_many!(account: account, account_provider: first, resources: %w[transactions activities])

      assert_raises(ActiveRecord::RecordInvalid) do
        Account::SourcePolicy.select!(account: account, account_provider: second, resource: "activities")
      end
      assert_equal [ first.id ], account.source_policies.active.distinct.pluck(:account_provider_id)

      Account::SourcePolicy.select_many!(account: account, account_provider: second, resources: %w[transactions activities])
      assert_equal [ second.id ], account.source_policies.active.distinct.pluck(:account_provider_id)
      assert_equal [ 2, 2 ], account.source_policies.active.order(:resource).pluck(:revision)
    end
  end

  test "a rescued invalid cash source switch preserves both authorities while the caller continues" do
    with_provider_encryption do
      account = accounts(:investment)
      first = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection))
      second = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection(provider_key: "plaid")))
      Account::SourcePolicy.select_many!(account: account, account_provider: first, resources: %w[transactions activities])
      before = account.source_policies.order(:id).map(&:attributes)

      Account.transaction(requires_new: true) do
        assert_raises(ActiveRecord::RecordInvalid) do
          Account::SourcePolicy.select!(account: account, account_provider: second, resource: "activities")
        end
        account.update!(name: "Caller continued after rejected selection")
      end

      assert_equal "Caller continued after rejected selection", account.reload.name
      assert_equal before, account.source_policies.order(:id).map(&:attributes)
      assert_equal [ [ "activities", first.id, 1 ], [ "transactions", first.id, 1 ] ],
        account.source_policies.active.order(:resource).pluck(:resource, :account_provider_id, :revision)
    end
  end

  test "a rescued second policy creation failure rolls back every changed resource and revision" do
    with_provider_encryption do
      account = accounts(:investment)
      first = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection))
      second = AccountProvider.create!(account: account, external_account: create_external_account(create_provider_connection(provider_key: "plaid")))
      resources = %w[transactions activities balances]
      Account::SourcePolicy.select_many!(account: account, account_provider: first, resources: resources)
      before = account.source_policies.order(:id).map(&:attributes)
      created_resources = []
      prior_creations = []
      fail_second = lambda do |policy|
        next unless policy.account_id == account.id && policy.account_provider_id == second.id

        created_resources << policy.resource
        if policy.resource == "activities"
          prior_creations << Account::SourcePolicy.active.exists?(account: account, account_provider: second, resource: "transactions")
          raise IOError, "Simulated second policy creation failure"
        end
      end
      Account::SourcePolicy.set_callback(:create, :after, fail_second)

      begin
        Account.transaction(requires_new: true) do
          assert_raises(IOError) do
            Account::SourcePolicy.select_many!(account: account, account_provider: second, resources: resources)
          end
          account.update!(name: "Caller continued after partial selection")
        end
      ensure
        Account::SourcePolicy.skip_callback(:create, :after, fail_second)
      end

      assert_equal %w[transactions activities], created_resources
      assert_equal [ true ], prior_creations
      assert_equal "Caller continued after partial selection", account.reload.name
      assert_equal before, account.source_policies.order(:id).map(&:attributes)

      selected = Account::SourcePolicy.select_many!(account: account, account_provider: second, resources: resources)
      assert_equal [ 2, 2, 2 ], selected.map(&:revision)
      assert_equal [ second.id ], account.source_policies.active.distinct.pluck(:account_provider_id)
      assert_equal 6, account.source_policies.count
    end
  end
end
