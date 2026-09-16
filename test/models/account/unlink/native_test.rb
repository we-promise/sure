require "test_helper"
require "timeout"
require_relative "../../../support/provider_ingestion_test_helper"
require_relative "../../../support/onchain_test_helper"

class Account::Unlink::NativeTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include OnchainTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Fence = Provider::AccountData::LegacyWriterFence
  Context = Data.define(:family, :user, :account, :accounts, :connections, :items, :sources, :users)
  Source = Data.define(:connection, :external, :link, :legacy, :item, :control)

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    register_fake_chain!
  end

  teardown do
    unregister_fake_chain!
    clear_enqueued_jobs
  end

  test "native unlink retains transactions source evidence policies and captured batch bytes" do
    with_context do |context|
      source = native_source(context)
      policy = select_policy(context, source, "transactions")
      page = transaction_page("up_retained")
      batch = capture_page(source, policy, page)
      apply_page(source, batch, page)
      entry = context.account.entries.find_by!(external_id: "up_retained")
      holding = holding_for(context.account, source.link)
      financial = [ entry.attributes, entry.transaction.attributes, holding.attributes.except("account_provider_id") ]
      evidence = evidence_rows(context)
      original_binding = policy.source_binding
      original_batch = raw_row(batch)

      assert unlink(context)

      refute context.account.reload.linked?
      refute AccountProvider.exists?(source.link.id)
      assert_nil holding.reload.account_provider_id
      assert_equal financial, [ entry.reload.attributes, entry.transaction.reload.attributes, holding.attributes.except("account_provider_id") ]
      assert_equal evidence, evidence_rows(context)
      assert_equal original_batch, raw_row(batch)
      refute policy.reload.active?
      assert_equal original_binding, policy.source_binding
      assert ExternalAccount.exists?(source.external.id)
      assert ProviderConnection.exists?(source.connection.id)
    end
  end

  test "native holdings retain their original holding provenance after detachment" do
    with_context do |context|
      source = native_source(context, key: "ibkr")
      policy = select_policy(context, source, "holdings")
      record = Ingestion::Record.holding(external_id: "position-aapl", date: Date.current, currency: "USD",
        quantity: BigDecimal("2"), price: BigDecimal("100"), amount: BigDecimal("200"), security: { ticker: "AAPL" })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot")
      batch = capture_page(source, policy, page)
      apply_page(source, batch, page, securities: { [ "holding", "position-aapl" ] => securities(:aapl) })
      holding = context.account.holdings.sole
      before = holding.attributes.except("account_provider_id")
      evidence = evidence_rows(context)

      assert unlink(context)

      assert_nil holding.reload.account_provider_id
      assert_equal before, holding.attributes.except("account_provider_id")
      assert_equal evidence, evidence_rows(context)
      assert_equal holding.id, HoldingSource.find_by!(account_id: context.account.id).holding_id
    end
  end

  test "native-owned CoinStats and Onchain dual links preserve their original tracking and copy evidence" do
    { "coinstats" => "active", "onchain_wallet" => "retired" }.each do |key, state|
      with_context do |context|
        source = migrated_source(context, key: key, state: state)
        policy = select_policy(context, source, "balances")
        holding = holding_for(context.account, source.link)
        originals = [ raw_row(source.legacy), raw_row(source.item), raw_row(source.control) ]
        archives = source.connection.ingestion_batches.order(:id).map { |batch| raw_row(batch) }
        receipts = ProviderMigrationAccountBinding.where(provider_migration_mapping_id: source.control.provider_migration_mappings.select(:id)).order(:id).map(&:attributes)

        assert unlink(context), key

        assert_equal originals, [ raw_row(source.legacy), raw_row(source.item), raw_row(source.control) ]
        assert_equal archives, source.connection.ingestion_batches.order(:id).map { |batch| raw_row(batch) }
        assert_equal receipts, ProviderMigrationAccountBinding.where(provider_migration_mapping_id: source.control.provider_migration_mappings.select(:id)).order(:id).map(&:attributes)
        assert_nil holding.reload.account_provider_id
        refute policy.reload.active?
        refute context.account.reload.linked?
      end
    end
  end

  test "a migrated direct SimpleFIN source survives native unlink while both financial links are cleared" do
    with_context do |context|
      source = migrated_source(context, key: "simplefin", direct: true)
      select_policy(context, source, "balances")
      before = raw_row(source.legacy)

      assert unlink(context)

      assert_nil context.account.reload.simplefin_account_id
      assert_empty context.account.account_providers
      assert_equal before, raw_row(source.legacy)
      assert SimplefinItem.exists?(source.item.id)
      assert ExternalAccount.exists?(source.external.id)
    end
  end

  test "mixed native and legacy links preserve native evidence and keep legacy tracking cleanup" do
    with_context do |context|
      source = native_source(context)
      policy = select_policy(context, source, "transactions")
      page = transaction_page("up_mixed")
      batch = capture_page(source, policy, page)
      apply_page(source, batch, page)
      legacy = legacy_source(context, key: "coinstats")
      native_holding = holding_for(context.account, source.link)
      legacy_holding = holding_for(context.account, legacy.link, date: Date.current - 1)
      evidence = evidence_rows(context)

      assert unlink(context)

      refute CoinstatsAccount.exists?(legacy.legacy.id)
      assert CoinstatsItem.exists?(legacy.item.id)
      assert ExternalAccount.exists?(source.external.id)
      assert_equal evidence, evidence_rows(context)
      assert_nil native_holding.reload.account_provider_id
      assert_nil legacy_holding.reload.account_provider_id
      refute context.account.reload.linked?
    end
  end

  test "unlinking one native account leaves the sibling account and connection unchanged" do
    with_context do |context|
      source = native_source(context)
      select_policy(context, source, "transactions")
      sibling = create_account(context, name: "Unaffected sibling")
      external = create_external_account(source.connection)
      link = AccountProvider.create!(account: sibling, external_account: external)
      policy = Account::SourcePolicy.select!(account: sibling, account_provider: link, resource: "transactions")
      holding = holding_for(sibling, link)
      before = [ raw_row(source.connection), sibling.attributes, external.attributes, link.attributes, policy.attributes, holding.attributes ]

      assert unlink(context)

      assert_equal before, [ raw_row(source.connection), sibling.reload.attributes, external.reload.attributes,
        link.reload.attributes, policy.reload.attributes, holding.reload.attributes ]
      assert sibling.linked?
    end
  end

  test "revoked account control refuses native unlink without deactivating policies or detaching holdings" do
    with_context do |context|
      source = native_source(context)
      policy = select_policy(context, source, "transactions")
      holding = holding_for(context.account, source.link)
      member = create_user(context.family, role: "member")
      context.users << member
      share = context.account.share_with!(member, permission: "full_control")
      context.account.account_shares.load
      request = Account::Unlink.new(account: context.account, user: member)
      share.update!(permission: "read_only")

      assert_raises(Account::Unlink::NotAuthorized) { request.call }

      assert policy.reload.active?
      assert_equal source.link.id, holding.reload.account_provider_id
      assert context.account.reload.linked?
    end
  end

  test "an already captured native writer cannot publish after its link is removed" do
    with_context do |context|
      source = native_source(context)
      policy = select_policy(context, source, "transactions")
      page = transaction_page("up_late")
      batch = capture_page(source, policy, page)
      writer = Ingestion::LedgerWriter.new(external_account: source.external, batch: batch)
      original_batch = raw_row(batch)
      assert unlink(context)

      assert_no_difference [ "Entry.count", "SourceRecord.count", "EntrySource.count" ] do
        assert_raises(Provider::AccountData::StaleWriter) do
          source.connection.with_lock { writer.apply(page) }
        end
      end

      assert_equal original_batch, raw_row(batch)
      refute context.account.reload.linked?
    end
  end

  test "a failure after the native link DELETE rolls back policy and holding changes" do
    with_context do |context|
      source = native_source(context)
      policy = select_policy(context, source, "transactions")
      holding = holding_for(context.account, source.link)
      before = [ source.link.attributes, policy.attributes, holding.attributes, context.account.attributes ]
      callback = lambda do |record|
        if record.id == context.account.id
          refute AccountProvider.exists?(source.link.id), "the native DELETE must precede this failure"
          raise IOError, "simulated unlink callback failure"
        end
      end
      Account.set_callback(:update, :after, callback)
      begin
        assert_raises(IOError) { unlink(context) }

        assert_equal before, [ source.link.reload.attributes, policy.reload.attributes,
          holding.reload.attributes, context.account.reload.attributes ]
      ensure
        Account.skip_callback(:update, :after, callback)
      end
    end
  end

  test "transitioning migration ownership refuses unlink without partially disconnecting either source" do
    %w[quiescing rollback_pending].each do |state|
      with_context do |context|
        source = migrated_source(context, key: "simplefin", state: state)
        legacy = legacy_source(context, key: "coinstats")
        holding = holding_for(context.account, source.link)

        assert_raises(Fence::OwnershipChanged) { unlink(context) }

        assert AccountProvider.exists?(source.link.id)
        assert AccountProvider.exists?(legacy.link.id)
        assert CoinstatsAccount.exists?(legacy.legacy.id)
        assert_equal source.link.id, holding.reload.account_provider_id
      end
    end
  end

  test "a locked native connection refuses unlink before any account mutation" do
    skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    with_context do |context|
      source = native_source(context)
      policy = select_policy(context, source, "transactions")
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          source.connection.class.transaction do
            ProviderConnection.lock.find(source.connection.id)
            ready << :locked
            release.pop
          end
        end
      rescue Exception => error
        ready << error
        raise
      end
      begin
        observed = Timeout.timeout(5) { ready.pop }
        raise observed if observed.is_a?(Exception)
        assert_equal :locked, observed

        assert_raises(Fence::Busy) { unlink(context) }

        assert policy.reload.active?
        assert AccountProvider.exists?(source.link.id)
      ensure
        release << true
        Timeout.timeout(5) { worker.value }
      end
    end
  end

  private
    def with_context(currency: "USD")
      with_provider_encryption do
        family = Family.create!(name: "Native unlink boundary")
        user = create_user(family)
        account = family.accounts.create!(owner: user, name: "Native unlink account", currency: currency,
          balance: 1000, accountable: Investment.new)
        context = Context.new(family: family, user: user, account: account, accounts: [ account ], connections: [],
          items: [], sources: [], users: [ user ])
        begin
          yield context
        ensure
          cleanup_context(context)
        end
      end
    end

    def create_user(family, role: "admin")
      family.users.create!(email: "unlink-#{SecureRandom.uuid}@example.com", password: "native-unlink-test-password", role: role)
    end

    def create_account(context, name:)
      context.family.accounts.create!(owner: context.user, name: name, currency: "USD", balance: 1000,
        accountable: Investment.new).tap { |account| context.accounts << account }
    end

    def native_source(context, key: "up")
      connection = create_provider_connection(family: context.family, provider_key: key, writer_epoch: 1)
      context.connections << connection
      external = create_external_account(connection, currency: context.account.currency,
        external_id: key == "ibkr" ? "U1234567" : SecureRandom.uuid)
      link = AccountProvider.create!(account: context.account, external_account: external)
      Source.new(connection: connection, external: external, link: link, legacy: nil, item: nil, control: nil)
    end

    def legacy_source(context, key:, direct: false)
      item, legacy = case key
      when "coinstats"
        item = CoinstatsItem.create!(family: context.family, name: "Retained CoinStats", api_key: "private-fixture-key")
        [ item, item.coinstats_accounts.create!(account_id: SecureRandom.uuid, name: "Retained wallet", currency: "USD", current_balance: 1000) ]
      when "onchain_wallet"
        item = create_onchain_wallet_item(family: context.family)
        [ item, create_onchain_wallet_account(item: item) ]
      when "simplefin"
        item = SimplefinItem.create!(family: context.family, name: "Retained SimpleFIN", access_url: "https://user:secret@bridge.example/access")
        [ item, item.simplefin_accounts.create!(account_id: SecureRandom.uuid, name: "Retained account", account_type: "investment", currency: "USD", current_balance: 1000) ]
      else
        raise ArgumentError, "Unsupported unlink source fixture"
      end
      context.items << item
      context.sources << legacy
      context.account.update!(simplefin_account: legacy) if direct
      link = AccountProvider.create!(account: context.account, provider: legacy)
      Source.new(connection: nil, external: nil, link: link, legacy: legacy, item: item, control: nil)
    end

    def migrated_source(context, key:, state: "active", direct: false)
      original = legacy_source(context, key: key, direct: direct)
      copier = Provider::AccountData::MigrationCopier.new(provider_key: key, legacy_item_id: original.item.id, batch_size: 1)
      control = nil
      20.times do
        control = copier.run.reload
        break if control.shadow?
      end
      assert control.shadow?, "fixture copy must finish before its ownership changes"
      connection = control.provider_connection
      context.connections << connection
      control.update!(state: state)
      link = original.link.reload
      Source.new(connection: connection, external: link.external_account, link: link, legacy: original.legacy,
        item: original.item, control: control)
    end

    def select_policy(context, source, resource)
      Account::SourcePolicy.select!(account: context.account, account_provider: source.link, resource: resource)
    end

    def holding_for(account, link, date: Date.current)
      account.holdings.create!(security: securities(:aapl), account_provider: link, date: date, qty: 2, price: 100,
        amount: 200, currency: account.currency)
    end

    def transaction_page(id)
      Provider::AccountData::Page.new(records: [ Ingestion::Record.transaction(external_id: id, name: "Retained transaction",
        currency: "USD", date: Date.current, amount: BigDecimal("12.34"), pending: false) ], complete: true, mode: "snapshot")
    end

    def capture_page(source, policy, page)
      create_provider_batch(source.connection, external_account: source.external, stream: policy.resource,
        source_policy_version: policy.id, payload: Ingestion::Codec.dump(page))
    end

    def apply_page(source, batch, page, securities: {})
      source.connection.with_lock do
        Ingestion::LedgerWriter.new(external_account: source.external, batch: batch, securities: securities).apply(page)
      end
    end

    def unlink(context)
      Account::Unlink.new(account: context.account, user: context.user).call
    end

    def raw_row(record)
      record.class.connection.select_one(record.class.where(id: record.id).to_sql)
    end

    def evidence_rows(context)
      [ SourceRecord, EntrySource, HoldingSource ].map do |model|
        model.where(account_id: context.account.id).order(:id).map { |record| raw_row(record) }
      end
    end

    def cleanup_context(context)
      account_ids = context.accounts.map(&:id)
      connection_ids = context.connections.map(&:id)
      controls = ProviderMigrationControl.where(provider_connection_id: connection_ids)
      context.items.each do |item|
        controls = controls.or(ProviderMigrationControl.where(legacy_type: item.class.base_class.name, legacy_id: item.id))
      end
      connection_ids |= controls.where.not(provider_connection_id: nil).pluck(:provider_connection_id)
      Account::SyncSource.where(account_id: account_ids).delete_all
      Sync.where(syncable_type: "Account", syncable_id: account_ids).destroy_all
      EntrySource.where(account_id: account_ids).delete_all
      HoldingSource.where(account_id: account_ids).delete_all
      SourceRecord.where(account_id: account_ids).delete_all
      Holding.where(account_id: account_ids).destroy_all
      ProviderMigrationAccountBinding.where(provider_migration_mapping_id: ProviderMigrationMapping.where(provider_migration_control_id: controls.select(:id)).select(:id)).delete_all
      ProviderSyncCheckpoint.where(provider_connection_id: connection_ids).delete_all
      IngestionBatch.where(provider_connection_id: connection_ids).delete_all
      Account::SourcePolicy.where(account_id: account_ids).delete_all
      AccountProvider.where(account_id: account_ids).delete_all
      ProviderMigrationMapping.where(provider_migration_control_id: controls.select(:id)).delete_all
      controls.delete_all
      ProviderConnection.where(id: connection_ids).find_each(&:destroy!)
      context.accounts.each do |account|
        next unless Account.exists?(account.id)
        account.reload.update_columns(simplefin_account_id: nil, plaid_account_id: nil)
        account.destroy!
      end
      context.sources.each { |source| source.class.where(id: source.id).delete_all }
      context.items.each { |item| item.class.where(id: item.id).delete_all }
      User.where(id: context.users.map(&:id)).delete_all
      context.family.destroy!
    end
end
