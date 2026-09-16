require "test_helper"
require "timeout"
require_relative "../../support/account_unlink_test_helper"
require_relative "../../support/identity_bootstrap_test_helper"

class Account::UnlinkTest < ActiveSupport::TestCase
  include AccountUnlinkTestHelper
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence

  setup do
    DebugLogEntry.stubs(:capture)
    register_fake_chain!
  end

  teardown do
    unregister_fake_chain!
  end

  test "direct SimpleFIN is deleted while an AP only SimpleFIN source survives" do
    [ true, false ].each do |direct|
      with_unlink_account do |context|
        source = add_unlink_source(context, "simplefin")
        context.account.update!(simplefin_account: source) if direct
        link = context.account.account_providers.sole
        holding = unlink_holding(context.account, link)
        before = holding.attributes.except("account_provider_id")

        assert command(context.account).call

        assert_equal !direct, SimplefinAccount.exists?(source.id)
        assert_not context.account.reload.linked?
        assert_nil holding.reload.account_provider_id
        assert_equal before, holding.attributes.except("account_provider_id")
      end
    end
  end

  test "CoinStats and Onchain tracking cleanup preserves financial rows and other sources" do
    with_unlink_account do |context|
      sources = %w[plaid coinstats onchain_wallet].map { |key| add_unlink_source(context, key) }
      links = context.account.account_providers.order(:id).to_a
      holding = unlink_holding(context.account, links.first)
      entry = context.account.entries.create!(entryable: Transaction.new, name: "Retained entry", amount: 12, currency: "USD", date: Date.current)
      before = entry.attributes

      assert command(context.account).call

      assert PlaidAccount.exists?(sources[0].id)
      assert_not CoinstatsAccount.exists?(sources[1].id)
      assert_not OnchainWalletAccount.exists?(sources[2].id)
      assert_not context.account.reload.linked?
      assert_equal before, entry.reload.attributes
      assert_nil holding.reload.account_provider_id
    end
  end

  test "a failed nonbang tracking callback rolls back links policies and holding detach" do
    [ "coinstats", "onchain_wallet" ].each do |key|
      with_unlink_account do |context|
        source = add_unlink_source(context, key)
        add_unlink_source(context, "plaid")
        link = context.account.account_providers.find_by!(provider: source)
        policy = Account::SourcePolicy.select!(account: context.account, account_provider: link, resource: "balances")
        holding = unlink_holding(context.account, link)
        links = context.account.account_providers.order(:id).map(&:attributes)
        source.class.any_instance.stubs(:destroy).returns(false)
        begin
          assert_raises(Account::Unlink::CleanupFailed) { command(context.account).call }

          assert_equal links, context.account.account_providers.order(:id).map(&:attributes)
          assert_equal link.id, holding.reload.account_provider_id
          assert Account::SourcePolicy.exists?(policy.id)
          assert policy.reload.active?
          assert source.class.exists?(source.id)
        ensure
          source.class.any_instance.unstub(:destroy)
        end
      end
    end
  end

  test "unlink deactivates a captured selection and retains its owner after tracking cleanup" do
    with_unlink_account do |context|
      source = add_unlink_source(context, "coinstats")
      link = context.account.account_providers.sole
      policy = Account::SourcePolicy.select!(account: context.account, account_provider: link, resource: "balances")
      original = policy.source_binding.deep_dup

      assert command(context.account).call

      refute AccountProvider.exists?(link.id)
      refute CoinstatsAccount.exists?(source.id)
      refute policy.reload.active?
      assert_equal original, policy.source_binding
      assert_equal context.items.sole.id, original.fetch("legacy_item_id")
      assert_equal context.account.id, policy.account_identity.id
    end
  end

  test "unlink refuses an unknown selection without changing its live link" do
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      link = context.account.account_providers.sole
      link.update!(family_id: context.account.family_id)
      Account::IngestionIdentity.capture!(account: context.account)
      Account::SourcePolicy.insert_all!([ { id: SecureRandom.uuid, account_id: context.account.id,
        family_id: context.account.family_id, account_provider_id: link.id,
        resource: "balances", revision: 1, active: false, source_binding: {} } ])

      assert_raises(Fence::OwnershipChanged) { command(context.account).call }

      assert link.reload.persisted?
      assert_empty Account::SourcePolicy.find_by!(account_id: context.account.id).source_binding
      assert context.account.reload.linked?
    end
  end

  test "failure deleting direct SimpleFIN rolls back completed link removals and direct FK clearing" do
    with_unlink_account do |context|
      source = add_unlink_source(context, "simplefin")
      context.account.update!(simplefin_account: source)
      link = context.account.account_providers.sole
      holding = unlink_holding(context.account, link)
      SimplefinAccount.any_instance.expects(:destroy!).raises(IOError, "private-credential-must-not-be-logged")
      DebugLogEntry.expects(:capture).with do |attributes|
        attributes[:account].id == context.account.id && attributes.dig(:metadata, :error_class) == "IOError" &&
          !attributes.to_s.include?("private-credential-must-not-be-logged")
      end

      assert_raises(IOError) { command(context.account).call }

      assert_equal source.id, context.account.reload.simplefin_account_id
      assert AccountProvider.exists?(link.id)
      assert_equal link.id, holding.reload.account_provider_id
    end
  end

  test "fresh permissions reject a revoked share and accept a newly granted full control share" do
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      member = users(:family_member)
      share = context.account.account_shares.create!(user: member, permission: "full_control")
      context.account.account_shares.load
      assert_equal :full_control, context.account.permission_for(member)
      request = command(context.account, user: member)
      share.update!(permission: "read_only")

      assert_raises(Account::Unlink::NotAuthorized) { request.call }
      assert context.account.reload.linked?

      share.update!(permission: "full_control")
      assert request.call
      assert_not context.account.reload.linked?
    end
  end

  test "owner rights are reloaded and another family's user cannot unlink" do
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      owner = users(:family_admin)
      request = command(context.account, user: owner)
      context.account.update!(owner: users(:family_member))

      assert_raises(Account::Unlink::NotAuthorized) { request.call }
      assert_raises(Account::Unlink::NotAuthorized) { command(context.account, user: users(:empty)).call }
      assert context.account.reload.linked?
    end
  end

  test "full control access unlinks an ownerless account without assigning a default owner" do
    with_unlink_account do |context|
      source = add_unlink_source(context, "plaid")
      context.account.update!(plaid_account: source)
      member = users(:family_member)
      context.account.account_shares.create!(user: member, permission: "full_control")
      # This persisted nullable state must survive unlink's direct FK cleanup;
      # ordinary Account validation would otherwise assign a default owner.
      context.account.update_columns(owner_id: nil)

      assert command(context.account, user: member).call

      assert_nil context.account.reload.owner_id
      assert_nil context.account.plaid_account_id
      assert_not context.account.linked?
      assert_equal :full_control, context.account.permission_for(member)
      assert PlaidAccount.exists?(source.id)
    end
  end

  test "foreign holdings are refused before detaching any row" do
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      link = context.account.account_providers.sole
      own = unlink_holding(context.account, link)
      with_unlink_account do |other|
        foreign = unlink_holding(other.account, link)

        assert_raises(Fence::OwnershipChanged) { command(context.account).call }

        assert_equal link.id, own.reload.account_provider_id
        assert_equal link.id, foreign.reload.account_provider_id
        assert AccountProvider.exists?(link.id)
      end
    end
  end

  test "a deactivated owner is refused even when the caller still has an active cached user" do
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      user = users(:family_admin)
      request = command(context.account, user: user)
      previous = user.active
      User.where(id: user.id).update_all(active: false)
      begin
        assert user.active?
        assert_raises(Account::Unlink::NotAuthorized) { request.call }
        assert context.account.reload.linked?
      ensure
        User.where(id: user.id).update_all(active: previous)
      end
    end
  end

  test "a different owner locked by another session causes Busy without unlinking a shared account" do
    skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    with_unlink_account do |context|
      add_unlink_source(context, "plaid")
      member = users(:family_member)
      context.account.account_shares.create!(user: member, permission: "full_control")
      link = context.account.account_providers.sole
      holding = unlink_holding(context.account, link)
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          User.transaction do
            User.lock.find(context.account.owner_id)
            ready << true
            release.pop
          end
        end
      end
      begin
        Timeout.timeout(5) { ready.pop }

        assert_raises(Fence::Busy) { command(context.account, user: member).call }

        assert AccountProvider.exists?(link.id)
        assert_equal link.id, holding.reload.account_provider_id
      ensure
        release << true
        begin
          Timeout.timeout(5) { worker.value }
        ensure
          worker.kill if worker.alive?
          worker.join
        end
      end
    end
  end

  test "a quiescing or native-only copied sibling prevents all cleanup" do
    with_identity_source(quiesced: false) do |context|
      holding = unlink_holding(context.account, context.link)
      context.control.update!(state: "quiescing")

      assert_raises(Fence::OwnershipChanged) { command(context.account).call }
      assert_equal context.link.id, holding.reload.account_provider_id
      context.control.update!(state: "shadow")
      # This branch represents an unselected native-only link. A selected link
      # cannot discard its captured legacy owner in the first place.
      Account::SourcePolicy.where(account_id: context.account.id).delete_all
      previous = context.link.attributes.slice("provider_type", "provider_id")
      context.link.update!(provider: nil)
      begin
        assert_raises(Fence::OwnershipChanged) { command(context.account).call }
        assert_equal context.link.id, holding.reload.account_provider_id
        assert AccountProvider.exists?(context.link.id)
      ensure
        context.link.update!(previous)
      end
    end
  end

  test "a source policy referenced by retained evidence prevents deletion of its history" do
    with_identity_source(quiesced: false) do |context|
      policy = context.account.source_policies.active.find_by!(resource: "transactions")
      batch = create_provider_batch(context.external.provider_connection, external_account: context.external,
        stream: "transactions", source_policy_version: policy.id, source_binding: {})
      holding = unlink_holding(context.account, context.link)
      original = batch.attributes

      assert_raises(Fence::OwnershipChanged) { command(context.account).call }

      assert Account::SourcePolicy.exists?(policy.id)
      assert AccountProvider.exists?(context.link.id)
      assert_equal context.link.id, holding.reload.account_provider_id
      assert_equal original, batch.reload.attributes
    end
  end

  test "unknown historical routing prevents unlink from overlooking a secondary policy" do
    with_identity_source(quiesced: false) do |context|
      policy = Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "balances")
      batch = create_provider_batch(context.external.provider_connection, external_account: context.external,
        stream: "historical_balances", source_policy_version: nil, source_binding: {},
        payload: { "balance_policy_version" => policy.id })
      IngestionBatch.any_instance.expects(:payload).never

      assert_raises(Ingestion::HistoricalBalances::SourceBinding::Incomplete) { command(context.account).call }

      assert context.link.reload.persisted?
      assert policy.reload.active?
      assert_empty batch.reload.source_binding
    end
  end

  private
    def command(account, user: users(:family_admin))
      Account::Unlink.new(account: account, user: user)
    end
end
