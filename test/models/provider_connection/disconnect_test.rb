require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class ProviderConnection::DisconnectTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false
  Disconnect = ProviderConnection::Disconnect
  Store = Provider::AccountData::CredentialStore

  setup do
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
  end

  test "disconnect preserves financial evidence and another provider across every linked account" do
    with_connection do |connection, actor|
      first, external, link, policies = linked_account(connection, actor)
      second, = linked_account(connection, actor)
      other = create_provider_connection(family: actor.family, provider_key: "mercury", name: "Other provider")
      other_external = create_external_account(other)
      other_link = AccountProvider.create!(account: first, external_account: other_external)
      other_policy = Account::SourcePolicy.select!(account: first, account_provider: other_link, resource: "holdings")
      entry = first.entries.create!(entryable: Transaction.new, name: "Protected history", date: Date.current,
        currency: "USD", amount: 12, import_locked: true, user_modified: true)
      batch = create_provider_batch(connection, external_account: external, stream: "transactions",
        scope_key: "account:#{external.id}", source_policy_version: policies.find { |policy| policy.resource == "transactions" }.id)
      batch.sync.update!(status: "completed", completed_at: Time.current)
      observation = SourceRecord.create!(family: actor.family, account: first, external_account: external,
        ingestion_batch: batch, kind: "transaction", external_id: "preserved-source")
      evidence = observation.entry_sources.create!(entry: entry, account: first, family: actor.family,
        role: "posting", match_method: "external_id")
      financial = [ first.reload.attributes, second.reload.attributes, entry.reload.attributes ]
      retained = [ observation.attributes, evidence.attributes, batch.attributes, other.reload.attributes, other_policy.attributes ]
      credentials = connection.reload.credentials
      command = Disconnect.new(connection: connection, actor: actor)
      form = command.form
      assert_equal [ first.id, second.id ].sort, form.accounts.map(&:id).sort
      refute_includes form.token, "private-provider-token"
      grant = Provider::AccountData::RequestGrant.new(connection).capture!
      Provider::Up.expects(:new).never

      result = command.call(token: form.token)

      refute result.replayed
      assert_equal connection.id, result.connection.id
      assert connection.reload.disabled?
      assert_equal 1, connection.writer_epoch
      assert_equal credentials, connection.credentials
      assert_equal 0, connection.credential_revision
      assert_empty connection.account_providers
      assert_equal [ other_link.id ], first.account_providers.reload.pluck(:id)
      refute link.persisted? && AccountProvider.exists?(link.id)
      assert policies.all? { |policy| !policy.reload.active? }
      assert other_policy.reload.active?
      assert_nil first.reload.provider
      assert_equal financial, [ first.reload.attributes, second.reload.attributes, entry.reload.attributes ]
      assert_equal retained, [ observation.reload.attributes, evidence.reload.attributes, batch.reload.attributes,
        other.reload.attributes, other_policy.reload.attributes ]
      assert_raises(Provider::AccountData::StaleWriter) { grant.verify! }
      refute ProviderConnection.syncable.exists?(connection.id)
      assert_includes Sync.for_family(actor.family).pluck(:id), batch.sync_id
    end
  end

  test "a completed disconnect replays after form expiry without changing the retained result" do
    with_connection do |connection, actor|
      linked_account(connection, actor)
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      command.call(token: token)
      before = connection.reload.attributes

      travel 1.day do
        assert command.call(token: token).replayed
      end

      assert_equal before, connection.reload.attributes
      assert_raises(Disconnect::Conflict) { command.form }
      assert_raises(Disconnect::Conflict) { command.call(token: token + "x") }
      other_actor = actor.family.users.create!(email: "other-disconnect-#{SecureRandom.uuid}@example.com",
        password: "disconnect-password", role: "admin")
      assert_raises(Disconnect::Conflict) { Disconnect.new(connection: connection, actor: other_actor).call(token: token) }
      actor.update!(role: "member")
      assert_raises(Disconnect::Conflict) { command.call(token: token) }
    end
  end

  test "a forged completion marker or changed disabled epoch cannot authorize replay" do
    with_connection do |connection, actor|
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      command.call(token: token)
      receipt = connection.reload.metadata.fetch(Disconnect::RECEIPT_KEY).deep_dup
      receipt["binding_digest"] = "0" * 64
      connection.update!(metadata: connection.metadata.merge(Disconnect::RECEIPT_KEY => receipt))
      assert_raises(Disconnect::Conflict) { command.call(token: token) }
    end
    with_connection do |connection, actor|
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      command.call(token: token)
      connection.reload.update!(writer_epoch: connection.writer_epoch + 1)
      assert_raises(Disconnect::Conflict) { command.call(token: token) }
    end
  end

  test "a disabled connection without this command receipt is not successful disconnection" do
    with_connection do |connection, actor|
      linked_account(connection, actor)
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      connection.update!(status: "disabled")
      assert_raises(Disconnect::Conflict) { command.call(token: token) }
      assert_equal 1, connection.account_providers.count
    end
  end

  test "completed receipts survive signing-key rotation when their original key remains retained" do
    with_connection do |connection, actor|
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      command.call(token: token)
      before = connection.reload.attributes
      keys = Rails.application.config.x.provider_identity_signing.deep_dup
      keys[:keys]["test-v2"] = [ "j" * 32 ].pack("m0")
      keys[:active_key_id] = "test-v2"
      Rails.application.config.x.provider_identity_signing = keys

      assert command.call(token: token).replayed
      assert_equal before, connection.reload.attributes

      keys[:keys].delete("test-v1")
      Rails.application.config.x.provider_identity_signing = keys
      assert_raises(Disconnect::Conflict) { command.call(token: token) }
    end
  end

  test "a completed receipt cannot acknowledge a connection that acquired a new live link" do
    with_connection do |connection, actor|
      account, external, = linked_account(connection, actor)
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      command.call(token: token)
      link = AccountProvider.create!(account: account, external_account: external)

      assert_raises(Disconnect::Conflict) { command.call(token: token) }

      assert AccountProvider.exists?(link.id)
      assert connection.reload.disabled?
    end
  end

  test "a stale review cannot detach a newly linked account or a changed source selection" do
    [ :new_link, :selection ].each do |change|
      with_connection do |connection, actor|
        account, _, link, = linked_account(connection, actor)
        command = Disconnect.new(connection: connection, actor: actor)
        token = command.form.token
        if change == :new_link
          linked_account(connection, actor)
        else
          Account::SourcePolicy.select!(account: account, account_provider: link, resource: "holdings")
        end
        before = connection.reload.attributes
        link_ids = connection.account_providers.pluck(:id).sort

        assert_raises(Disconnect::Conflict) { command.call(token: token) }

        assert_equal before, connection.reload.attributes
        assert_equal link_ids, connection.account_providers.pluck(:id).sort
      end
    end
  end

  test "current permissions are checked for every affected account and stale shares are rejected" do
    with_connection do |connection, actor|
      _, _, first_link, = linked_account(connection, actor)
      member = actor.family.users.create!(email: "private-disconnect-#{SecureRandom.uuid}@example.com",
        password: "disconnect-password", role: "member")
      account, _, second_link, = linked_account(connection, member)
      command = Disconnect.new(connection: connection, actor: actor)
      assert_raises(Disconnect::Conflict) { command.form }
      share = account.account_shares.create!(user: actor, permission: "full_control")
      token = command.form.token
      share.update!(permission: "read_only")

      assert_raises(Disconnect::Conflict) { command.call(token: token) }

      assert connection.reload.good?
      assert AccountProvider.exists?(first_link.id)
      assert AccountProvider.exists?(second_link.id)
    end
  end

  test "cross-connection cross-family malformed and expired forms do not change links" do
    with_connection do |connection, actor|
      linked_account(connection, actor)
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      other = create_provider_connection(family: actor.family)
      assert_raises(Disconnect::Conflict) { Disconnect.new(connection: other, actor: actor).call(token: token) }
      assert_raises(Disconnect::Conflict) { Disconnect.new(connection: connection, actor: users(:family_admin)).call(token: token) }
      [ nil, "", "invalid", "x" * (Disconnect::MAX_TOKEN_BYTES + 1) ].each do |bad|
        assert_raises(Disconnect::Conflict) { command.call(token: bad) }
      end
      travel 31.minutes do
        assert_raises(Disconnect::Conflict) { command.call(token: token) }
      end
      assert connection.reload.good?
      assert_equal 1, connection.account_providers.count
    end
  end

  test "a failed signing step rolls back detachment and source deactivation" do
    with_connection do |connection, actor|
      _, _, link, policies = linked_account(connection, actor)
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      before = connection.reload.attributes
      Ingestion::IdentitySigningKeys.any_instance.expects(:sign).raises(Ingestion::IdentitySigningKeys::InvalidConfiguration)

      assert_raises(Disconnect::Conflict) { command.call(token: token) }

      assert_equal before, connection.reload.attributes
      assert AccountProvider.exists?(link.id)
      assert policies.all? { |policy| policy.reload.active? }
    end
  end

  test "pending native work abandoned leases and unfinished generations each prevent disconnection" do
    [ :sync, :lease, :generation ].each do |kind|
      with_connection do |connection, actor|
        command = Disconnect.new(connection: connection, actor: actor)
        token = command.form.token
        case kind
        when :sync
          connection.syncs.create!
        when :lease
          connection.update!(lease_owner: "abandoned", lease_expires_at: 1.hour.ago)
        when :generation
          sync = connection.syncs.create!(status: "failed", completed_at: Time.current)
          connection.provider_sync_generations.create!(family: actor.family, sync: sync, stream: "transactions",
            scope_key: "connection", status: "fetching", writer_epoch: connection.writer_epoch, context_snapshot: {})
        end
        before = connection.reload.attributes
        assert_raises(Disconnect::Busy) { command.call(token: token) }
        assert_raises(Disconnect::Busy) { command.form }
        assert_equal before, connection.reload.attributes
      end
    end
  end

  test "stopped uncertain credentials retain their original evidence without becoming usable" do
    with_connection do |connection, actor|
      connection.update!(status: "requires_update", credential_state: { "status" => "uncertain", "attempt_id" => SecureRandom.uuid })
      before = [ connection.credentials, connection.credential_state, connection.credential_revision ]
      command = Disconnect.new(connection: connection, actor: actor)
      command.call(token: command.form.token)
      assert connection.reload.disabled?
      assert_equal before, [ connection.credentials, connection.credential_state, connection.credential_revision ]
      assert_raises(Provider::AccountData::StaleWriter) { Store.new(connection: connection).with_session_lock(&:credentials) }
    end
  end

  test "a live credential operation and an enclosing transaction exclude disconnection" do
    with_connection do |connection, actor|
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      before = connection.reload.attributes
      assert_raises(ArgumentError) { ProviderConnection.transaction { command.call(token: token) } }
      Store.with_connection_lock(connection_id: connection.id) do
        assert_raises(Disconnect::Busy) { command.call(token: token) }
      end
      assert_equal before, connection.reload.attributes
    end
  end

  test "another database session holding the credential lock prevents disconnect without partial changes" do
    skip "requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    with_connection do |connection, actor|
      linked_account(connection, actor)
      command = Disconnect.new(connection: connection, actor: actor)
      token = command.form.token
      Store.with_connection_lock(connection_id: connection.id) do
        worker = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            command.call(token: token)
            :unexpected
          rescue Disconnect::Busy
            :busy
          end
        end
        begin
          assert_equal :busy, Timeout.timeout(10) { worker.value }
        ensure
          worker.kill if worker.alive?
          worker.join
        end
      end
      assert connection.reload.good?
      assert_equal 1, connection.account_providers.count
    end
  end

  private
    def linked_account(connection, actor)
      account = actor.family.accounts.create!(owner: actor, name: "Disconnect checking", currency: "USD",
        balance: 100, cash_balance: 100, accountable: Depository.new, status: "active")
      external = create_external_account(connection)
      link = AccountProvider.create!(account: account, external_account: external)
      policies = Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: %w[balances transactions])
      [ account, external, link, policies ]
    end

    def with_connection
      with_provider_encryption do
        family = Family.create!(name: "Native disconnect")
        actor = family.users.create!(email: "native-disconnect-#{SecureRandom.uuid}@example.com", password: "disconnect-password", role: "admin")
        connection = create_provider_connection(family: family)
        yield connection, actor
      ensure
        cleanup_family(family) if family
      end
    end

    def cleanup_family(family)
      connections = family.provider_connections.to_a
      observations = SourceRecord.where(family_id: family.id)
      EntrySource.where(source_record_id: observations.select(:id)).delete_all
      HoldingSource.where(source_record_id: observations.select(:id)).delete_all
      observations.delete_all
      ProviderSyncCheckpoint.where(family_id: family.id).delete_all
      IngestionBatch.where(family_id: family.id).delete_all
      ProviderSyncGeneration.where(family_id: family.id).delete_all
      Account::SourcePolicy.where(family_id: family.id).delete_all
      AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
      connections.each do |connection|
        connection.update_columns(lease_owner: nil, lease_expires_at: nil, lease_sync_id: nil)
        connection.syncs.destroy_all
        connection.reload.destroy!
      end
      family.accounts.destroy_all
      family.users.destroy_all
      family.destroy!
    end
end
