require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class EnableBankingItem::LifecycleTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false
  Command = EnableBankingItem::Lifecycle
  Fence = Command::Fence

  setup { DebugLogEntry.stubs(:capture) }

  test "signed callback installs the original source atomically and dispatches after release exactly once" do
    with_context do |item, actor, source, account, client|
      original_session = item.session_id
      client.on_request = lambda do |operation|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        if operation == :session
          assert_equal "claiming", Command.attempt(item.reload).fetch("state")
          assert item.requires_update?
          assert_equal original_session, item.session_id
        end
      end
      authorize(item, actor)
      state = client.state
      SyncJob.expects(:perform_later).with do |sync|
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        assert_equal 0, ApplicationRecord.connection.open_transactions
        sync.syncable_id == item.id && sync.pending?
      end.twice
      result = callback(state, actor)
      assert_equal item.id, result.id
      assert_equal "installed-session", item.reload.session_id
      assert item.good?
      assert_nil item.authorization_id
      assert_equal "completed", Command.attempt(item).fetch("state")
      assert_equal "preserved", item.raw_institution_payload["institution"]
      assert_equal account.id, source.reload.account_provider.account_id
      assert_equal "refreshed-api-id", source.api_account_id
      assert_equal [ source.id ], item.enable_banking_accounts.pluck(:id)
      assert_equal 1, item.syncs.count
      sync_id = item.syncs.sole.id
      callback(state, actor)
      assert_equal [ sync_id ], item.syncs.pluck(:id)
      Sync.where(id: sync_id).update_all(status: "completed")
      assert_raises(Fence::OwnershipChanged) { callback(state, actor) }
      assert_equal 1, client.calls.count(:session)
      refute_includes item.raw_institution_payload.to_json, "single-use-secret-code"
    end
  end

  test "raw item UUID tampered state other actor and other family cannot exchange" do
    with_context do |item, actor, _source, _account, client|
      authorize(item, actor)
      another = user(item.family)
      other_family = Family.create!(name: "Other consent family")
      foreign = user(other_family)
      [ item.id, client.state + "changed", nil, { state: client.state } ].each do |state|
        assert_raises(Fence::OwnershipChanged) { callback(state, actor) }
      end
      [ another, foreign ].each { |candidate| assert_raises(Fence::OwnershipChanged) { callback(client.state, candidate) } }
      assert_equal 0, client.calls.count(:session)
    ensure
      other_family&.users&.delete_all
      other_family&.destroy!
    end
  end

  test "fresh administrator and account permissions are checked before and after transport" do
    with_context do |item, actor, _source, account, client|
      authorize(item, actor)
      actor.update!(role: "member")
      assert_raises(Fence::OwnershipChanged) { callback(client.state, actor) }
      assert_equal 0, client.calls.count(:session)
      actor.update!(role: "admin")
      client.on_request = ->(operation) { account.update!(owner: user(item.family)) if operation == :session }
      assert_raises(Fence::OwnershipChanged) { callback(client.state, actor) }
      assert_equal "original-session", item.reload.session_id
      assert_equal "claiming", Command.attempt(item).fetch("state")
    end
  end

  test "uncertain session exchange is never replayed and explicit new authorization invalidates old state" do
    with_context do |item, actor, _source, _account, client|
      authorize(item, actor)
      original = client.state
      client.on_request = ->(operation) { raise IOError, "private upstream body" if operation == :session }
      assert_raises(IOError) { callback(original, actor) }
      assert_equal "uncertain", Command.attempt(item.reload).fetch("state")
      assert_not item.session_valid?
      assert_equal "original-session", item.session_id
      assert_raises(Fence::OwnershipChanged) { callback(original, actor) }
      client.on_request = nil
      authorize(item.reload, actor)
      refute_equal original, client.state
      assert_raises(Fence::OwnershipChanged) { callback(original, actor) }
      callback(client.state, actor)
      assert_equal 2, client.calls.count(:session)
    end
  end

  test "failure installing the response rolls back every account and retains consumed-attempt refusal" do
    with_context do |item, actor, source, account, client|
      authorize(item, actor)
      original = [ source.attributes, account.attributes ]
      failure = -> { raise "installation failed" if name == "Installed name" }
      EnableBankingAccount.set_callback(:save, :after, failure)
      assert_raises(RuntimeError) { callback(client.state, actor) }
      assert_equal original, [ source.reload.attributes, account.reload.attributes ]
      assert_empty item.syncs
      assert_equal "original-session", item.reload.session_id
      assert_equal "uncertain", Command.attempt(item).fetch("state")
      assert_raises(Fence::OwnershipChanged) { callback(client.state, actor) }
      assert_equal 1, client.calls.count(:session)
    ensure
      EnableBankingAccount.skip_callback(:save, :after, failure) if failure
    end
  end

  test "response cannot overwrite a replaced original session" do
    with_context do |item, actor, source, _account, client|
      authorize(item, actor)
      original = source.attributes
      client.on_request = ->(operation) { item.update!(session_id: "replacement-consent") if operation == :session }
      assert_raises(Fence::OwnershipChanged) { callback(client.state, actor) }
      assert_equal "replacement-consent", item.reload.session_id
      assert_equal original, source.reload.attributes
      assert_equal "claiming", Command.attempt(item).fetch("state")
      assert_empty item.syncs
    end
  end

  test "queue failure preserves the committed session and original pending sync without repeating the exchange" do
    with_context do |item, actor, _source, _account, client|
      authorize(item, actor)
      SyncJob.expects(:perform_later).raises(IOError, "queue unavailable")
      assert_raises(IOError) { callback(client.state, actor) }
      assert_equal "completed", Command.attempt(item.reload).fetch("state")
      assert_equal "installed-session", item.session_id
      sync = item.syncs.sole
      assert sync.pending?
      SyncJob.expects(:perform_later).with { |queued| queued.id == sync.id }.once
      callback(client.state, actor)
      assert_equal [ sync.id ], item.syncs.pluck(:id)
      assert_equal 1, client.calls.count(:session)
    end
  end

  test "stale commands do not adopt replacement credentials" do
    with_context do |item, actor, _source, _account, client|
      command = Command.new(item: item, actor: actor)
      item.update!(session_id: "replacement")
      assert_raises(Fence::OwnershipChanged) { command.update_settings(name: "Stale rename") }
      assert_equal "Consent fixture", item.reload.name
      assert_empty client.calls
    end
  end

  test "completed callback refuses inventory drift and never manufactures a replacement sync" do
    with_context do |item, actor, source, _account, client|
      authorize(item, actor)
      callback(client.state, actor)
      sync_id = item.syncs.sole.id
      source.update!(raw_transactions_payload: [ { "transaction_id" => "newer-cache" } ])
      SyncJob.expects(:perform_later).never
      assert_raises(Fence::OwnershipChanged) { callback(client.state, actor) }
      assert_equal [ sync_id ], item.syncs.pluck(:id)
      assert_equal 1, client.calls.count(:session)
    end
  end

  test "session account alias collisions duplicate API routes and absent inventory roll back installation" do
    [ :aliases, :routes, :missing ].each do |kind|
      with_context do |item, actor, source, _account, client|
        source.update!(identification_hashes: [ "older-alias" ])
        authorize(item, actor)
        original = source.reload.attributes
        first = { identification_hash: "stable-source", uid: "route-one", name: "First", currency: "EUR" }
        second = { identification_hash: kind == :aliases ? "older-alias" : "other-source",
          uid: kind == :routes ? "route-one" : "route-two", name: "Second", currency: "EUR" }
        client.session_response = kind == :missing ? { session_id: "new" } : { session_id: "new", accounts: [ first, second ] }
        assert_raises(Fence::OwnershipChanged) { callback(client.state, actor) }
        assert_equal original, source.reload.attributes
        assert_equal [ source.id ], item.enable_banking_accounts.pluck(:id)
        assert_equal "original-session", item.reload.session_id
        assert_equal "uncertain", Command.attempt(item).fetch("state")
        assert_empty item.syncs
      end
    end
  end

  test "credential changes preserve old session and require a new authorization" do
    with_context do |item, actor|
      result = Command.new(item: item, actor: actor).update_settings(application_id: "replacement-app", client_certificate: "")
      assert_empty result.errors
      assert_equal "replacement-app", item.reload.application_id
      assert_equal "original-session", item.session_id
      assert_equal "fixture-certificate", item.client_certificate
      assert_not item.session_valid?
    end
  end

  test "reserved namespace collision refuses all consent mutations before HTTP" do
    with_context do |item, actor, _source, _account, client|
      item.update!(raw_institution_payload: { Command::KEY => { "unexpected" => "data" }, "institution" => "preserved" })
      assert_raises(Fence::OwnershipChanged) { authorize(item, actor) }
      assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).update_settings(name: "Bad") }
      assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).disconnect }
      assert_empty client.calls
      assert_equal "preserved", item.reload.raw_institution_payload["institution"]
    end
  end

  test "copy gate is provider scoped and refuses legacy pending authorization or an unresolved attempt" do
    assert Command.assert_copyable!(UpItem.new)
    with_context do |item, actor, _source, _account, client|
      assert Command.assert_copyable!(item)
      item.update!(authorization_id: "preexisting-authorization")
      assert_raises(Fence::OwnershipChanged) { Command.assert_copyable!(item) }
      item.update!(authorization_id: nil)
      authorize(item, actor)
      assert_raises(Fence::OwnershipChanged) { Command.assert_copyable!(item.reload) }
      callback(client.state, actor)
      assert Command.assert_copyable!(item.reload)
    end
  end

  test "local disconnect refusal neither revokes remote consent nor destroys source links" do
    with_context do |item, actor, source, account, client|
      link = source.account_provider
      policy = Account::SourcePolicy.select!(account: account, account_provider: link, resource: "transactions")
      original = [ item.attributes, source.attributes, link.attributes, policy.attributes ]
      DestroyJob.expects(:perform_later).never
      assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).disconnect }
      assert_empty client.calls
      assert_equal original, [ item.reload.attributes, source.reload.attributes, link.reload.attributes, policy.reload.attributes ]
    end
  end

  test "disconnect commits local intent before remote revoke and schedules only confirmed success after release" do
    with_context do |item, actor, source, account, client|
      original = account.attributes
      client.on_request = lambda do |operation|
        next unless operation == :delete
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_nil source.reload.account_provider
        assert_equal "revoking", Command.attempt(item.reload).fetch("state")
        assert_equal "disconnect", Command.attempt(item).fetch("operation")
        assert_equal "original-session", item.session_id
        assert_not item.scheduled_for_deletion?
      end
      DestroyJob.expects(:perform_later).with do |current|
        assert_nil ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        current.id == item.id && current.scheduled_for_deletion?
      end.twice
      Command.new(item: item, actor: actor).disconnect
      assert_equal "revoked", Command.attempt(item.reload).fetch("state")
      assert_nil item.session_id
      assert_equal original, account.reload.attributes
      assert source.reload.persisted?
      Command.new(item: item.reload, actor: actor).disconnect
      assert_equal 1, client.calls.count(:delete)
    end
  end

  test "failed remote disconnect keeps original consent and a blocked intent without claiming deletion" do
    with_context do |item, actor, source, account, client|
      client.on_request = ->(operation) { raise IOError, "private DELETE failure" if operation == :delete }
      DestroyJob.expects(:perform_later).never
      assert_raises(IOError) { Command.new(item: item, actor: actor).disconnect }
      assert_nil source.reload.account_provider
      assert_equal "original-session", item.reload.session_id
      assert_not item.scheduled_for_deletion?
      assert_equal "uncertain", Command.attempt(item).fetch("state")
      assert account.reload.persisted?
      assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).disconnect }
      assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).revoke_session }
      assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).update_settings(application_id: "new") }
      assert_raises(Fence::OwnershipChanged) { authorize(item, actor) }
      assert_equal 1, client.calls.count(:delete)
    end
  end

  test "an interrupted disconnect before DELETE resumes its committed original session intent" do
    with_context do |item, actor, source, _account, client|
      failure = -> { raise "stopped after local commit" if Command.attempt(self)&.fetch("state") == "disconnect_pending" }
      EnableBankingItem.set_callback(:commit, :after, failure)
      assert_raises(RuntimeError) { Command.new(item: item, actor: actor).disconnect }
      assert_nil source.reload.account_provider
      assert_equal "disconnect_pending", Command.attempt(item.reload).fetch("state")
      assert_equal 0, client.calls.count(:delete)
      EnableBankingItem.skip_callback(:commit, :after, failure)
      failure = nil
      Command.new(item: item, actor: actor).disconnect
      assert item.reload.scheduled_for_deletion?
      assert_equal 1, client.calls.count(:delete)
    ensure
      EnableBankingItem.skip_callback(:commit, :after, failure) if failure
    end
  end

  test "failed local unlink rolls back intent and makes no remote call" do
    with_context do |item, actor, source, _account, client|
      AccountProvider.any_instance.expects(:destroy!).raises(ActiveRecord::RecordNotDestroyed)
      assert_raises(ActiveRecord::RecordNotDestroyed) { Command.new(item: item, actor: actor).disconnect }
      assert source.reload.account_provider
      assert_nil Command.attempt(item.reload)
      assert item.good?
      assert_empty client.calls
    end
  end

  test "transitional and native ownership refuse before configuration or revocation" do
    %w[quiescing active retired].each do |state|
      with_context do |item, actor, _source, _account, client|
        ProviderMigrationControl.create!(family: item.family, provider_key: "enable_banking", legacy_type: "EnableBankingItem", legacy_id: item.id, state: state)
        original = item.attributes
        assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).update_settings(name: "Changed") }
        assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).revoke_session }
        assert_raises(Fence::OwnershipChanged) { Command.new(item: item, actor: actor).disconnect }
        assert_equal original, item.reload.attributes
        assert_empty client.calls
      end
    end
  end

  test "a real competing publication permit refuses lifecycle without an HTTP transaction or request" do
    with_context do |item, actor, _source, _account, client|
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Fence.with_item(item) do
            ready << true
            release.pop
          end
        end
      rescue Exception => error
        ready << error
      end
      signal = Timeout.timeout(5) { ready.pop }
      raise signal if signal.is_a?(Exception)
      assert_raises(Fence::Busy) { authorize(item, actor) }
      assert_empty client.calls
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  private
    def authorize(item, actor)
      Command.new(item: item, actor: actor).begin_authorization!(aspsp_name: "Fixture Bank", redirect_url: "https://example.com/callback")
    end

    def callback(state, actor)
      Command.from_state(state, actor: actor).complete_authorization(code: "single-use-secret-code")
    end

    def user(family)
      family.users.create!(email: "enable-consent-#{SecureRandom.uuid}@example.com", password: "consent-test-password", role: "admin")
    end

    def with_context
      with_provider_encryption do
        family = Family.create!(name: "Consent lifecycle", timezone: "UTC")
        actor = user(family)
        item = family.enable_banking_items.create!(name: "Consent fixture", country_code: "FI", application_id: SecureRandom.uuid,
          client_certificate: "fixture-certificate", session_id: "original-session", session_expires_at: 1.day.from_now,
          raw_institution_payload: { "institution" => "preserved" })
        source = item.enable_banking_accounts.create!(uid: "stable-source", account_id: "original-api-id", name: "Original name", currency: "EUR", raw_transactions_payload: [])
        account = family.accounts.create!(owner: actor, name: "Financial account", balance: 10, currency: "EUR", accountable: Depository.new)
        AccountProvider.create!(account: account, provider: source)
        client = Client.new
        client.on_request = ->(_operation) { assert_equal 0, ApplicationRecord.connection.open_transactions }
        EnableBankingItem.any_instance.stubs(:enable_banking_provider).returns(client)
        yield item, actor, source, account, client
      ensure
        if family
          Account::SourcePolicy.where(family_id: family.id).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.accounts.each(&:destroy!)
          ProviderMigrationControl.where(family_id: family.id).delete_all
          ids = family.enable_banking_items.pluck(:id)
          Sync.where(syncable_type: "EnableBankingItem", syncable_id: ids).destroy_all
          EnableBankingAccount.where(enable_banking_item_id: ids).delete_all
          EnableBankingItem.where(id: ids).delete_all
          Session.where(user_id: family.users.select(:id)).delete_all
          family.users.delete_all
          family.destroy!
        end
        clear_enqueued_jobs
      end
    end

    class Client
      attr_accessor :on_request, :session_response
      attr_reader :state, :calls
      def initialize = @calls = []
      def get_aspsps(country:)
        request(:banks)
        { aspsps: [ { name: "Fixture Bank", psu_types: [ "personal" ], auth_methods: [ { name: "redirect", approach: "REDIRECT" } ] } ] }
      end
      def start_authorization(**attributes)
        @state = attributes.fetch(:state)
        request(:start)
        { authorization_id: SecureRandom.uuid, url: "https://api.enablebanking.com/auth/fixture" }
      end
      def create_session(code:)
        request(:session)
        return session_response if session_response
        { session_id: "installed-session", access: { valid_until: 1.day.from_now.iso8601 },
          accounts: [ { identification_hash: "stable-source", uid: "refreshed-api-id", name: "Installed name", currency: "EUR" } ] }
      end
      def delete_session(session_id:)
        raise "Wrong session" unless session_id == "original-session"
        request(:delete)
        {}
      end
      private
        def request(operation)
          @calls << operation
          on_request&.call(operation)
        end
    end
end
