require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Account::Unlink::LegacyAccessTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Access = Account::Unlink::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "all direct legacy and copied links are admitted together without changing financial data" do
    with_identity_source(quiesced: false) do |context|
      with_plaid_link(context) do |item, source, link|
        context.account.update!(plaid_account: source)
        before = identity_financial_snapshot(context)
        seen = nil

        Access.with_account(context.account) do |current|
          assert_not_same context.account, current
          assert_equal context.account.id, current.id
          assert_operator ApplicationRecord.connection.open_transactions, :>, 0
          Fence.with_item(context.item, operation: :lifecycle) { |up| assert_equal context.item.id, up.id }
          Fence.with_item(item, operation: :lifecycle) { |plaid| assert_equal item.id, plaid.id }
          seen = current.account_providers.order(:id).pluck(:id)
        end

        assert_equal [ context.link.id, link.id ].sort, seen
        assert_equal before, identity_financial_snapshot(context)
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
      end
    end
  end

  test "one quiescing or native owned sibling prevents the whole unlink operation" do
    with_identity_source(quiesced: false) do |context|
      with_plaid_link(context) do |_item, _source, _link|
        %w[quiescing active rollback_pending retired].each do |state|
          context.control.update!(state: state)
          before = identity_financial_snapshot(context)
          links = context.account.account_providers.order(:id).map(&:attributes)

          assert_raises(Fence::OwnershipChanged) do
            Access.with_account(context.account) { flunk "No member may mutate after refused group admission" }
          end

          assert_equal before, identity_financial_snapshot(context)
          assert_equal links, context.account.account_providers.order(:id).map(&:attributes)
          assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        end
      end
    end
  end

  test "an account link reparented after initial inventory cannot expand the admitted set" do
    with_identity_source(quiesced: false) do |context|
      with_plaid_link(context) do |_item, source, _link|
        replacement = PlaidItem.create!(family: context.family, name: "Replacement owner", access_token: "private-other-token",
          plaid_id: SecureRandom.uuid, plaid_region: "eu")
        original_id = source.plaid_item_id
        begin
          access = changing_inventory(context.account) { source.update!(plaid_item: replacement) }

          assert_raises(Fence::OwnershipChanged) { access.with_account { flunk "A changed source cannot be unlinked" } }

          assert context.account.account_providers.exists?(provider: source)
          assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        ensure
          source.update!(plaid_item_id: original_id)
          replacement.delete
        end
      end
    end
  end

  test "a direct link appearing after capture is rejected even when its item is already admitted" do
    with_identity_source(quiesced: false) do |context|
      with_plaid_link(context) do |_item, source, _link|
        access = changing_inventory(context.account) { context.account.update!(plaid_account: source) }

        assert_raises(Fence::OwnershipChanged) { access.with_account { flunk "Changed topology must restart admission" } }

        assert_equal source.id, context.account.reload.plaid_account_id
      end
    end
  end

  test "native only links cannot be hidden from the legacy inventory" do
    with_identity_source(quiesced: false) do |context|
      # This inventory fixture has no selected policy. A selected link cannot
      # change its captured legacy identity in the first place.
      Account::SourcePolicy.where(account_provider_id: context.link.id).delete_all
      original = context.link.attributes.slice("provider_type", "provider_id")
      begin
        context.link.update!(provider: nil)

        assert_raises(Fence::OwnershipChanged) { Access.with_account(context.account) { flunk "Native unlink requires its own command" } }

        assert AccountProvider.exists?(context.link.id)
      ensure
        context.link.update!(original)
      end
    end
  end

  test "unknown provider classes and changed item families fail before mutation" do
    with_identity_source(quiesced: false) do |context|
      Account::SourcePolicy.where(account_provider_id: context.link.id).delete_all
      begin
        context.link.update_columns(provider_type: "UnregisteredAccount")
        assert_raises(Fence::InvalidSource) { Access.with_account(context.account) { flunk } }
      ensure
        context.link.update_columns(provider_type: "UpAccount")
      end
      begin
        context.item.update_columns(family_id: families(:empty).id)
        assert_raises(Fence::OwnershipChanged) { Access.with_account(context.account) { flunk } }
      ensure
        context.item.update_columns(family_id: context.family.id)
      end
      assert AccountProvider.exists?(context.link.id)
    end
  end

  test "manual account admission retains an empty permit and permits ordinary financial edits" do
    account = families(:dylan_family).accounts.create!(name: "Manual unlink context", currency: "USD", balance: 0, accountable: Depository.new)
    begin
      account.transaction do
        Access.with_account(account) do |current|
          assert_empty current.account_providers
          current.update!(name: "Still manual")
        end
      end
      assert_equal "Still manual", account.reload.name
      assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
    ensure
      account.destroy!
    end
  end

  test "failed cleanup rolls back inside an admitted transaction whose caller continues" do
    with_identity_source(quiesced: false) do |context|
      with_plaid_link(context) do |item, source, link|
        context.account.update!(plaid_account: source)

        Fence.with_items([ context.item, item ], operation: :lifecycle) do
          Account.transaction do
            assert_raises(RuntimeError) do
              Access.with_account(context.account) do |current|
                current.update!(plaid_account_id: nil)
                current.account_providers.find(link.id).destroy!
                raise "Cleanup failed after removing a link"
              end
            end
            Account.where(id: context.account.id).update_all(name: "Caller continues")
          end
        end

        assert AccountProvider.exists?(link.id), "A failed unlink must retain its provider links"
        assert_equal source.id, context.account.reload.plaid_account_id
        assert_equal "Caller continues", context.account.name
      end
    end
  end

  private
    def with_plaid_link(context)
      item = PlaidItem.create!(family: context.family, name: "Other provider", access_token: "private-plaid-token",
        plaid_id: SecureRandom.uuid, plaid_region: "eu")
      source = item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Checking", currency: "USD", plaid_type: "depository", current_balance: 1)
      link = AccountProvider.create!(account: context.account, provider: source)
      yield item, source, link
    ensure
      context.account.update_columns(plaid_account_id: nil) if context.account.persisted?
      Account::SourcePolicy.where(account_provider_id: link.id).delete_all if link
      link&.delete
      source&.delete
      item&.delete
    end

    def changing_inventory(account, &change)
      Class.new(Access) do
        define_method(:initialize) do |selected|
          super(selected)
          @change_once = change
        end

        private
          def snapshot
            captured = super
            change = @change_once
            @change_once = nil
            change&.call
            captured
          end
      end.new(account)
    end
end
