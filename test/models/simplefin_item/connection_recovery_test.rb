require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinItem::ConnectionRecoveryTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Command = SimplefinItem::ConnectionUpdate
  Fence = Provider::AccountData::LegacyWriterFence
  RESPONSE_URL = "https://recovery-user:private-password@example.com/saved-access".freeze

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    Provider::Simplefin.any_instance.expects(:claim_access_url).never
  end

  test "retry queues only the original claim IDs for prepared claimed and installed pending requests" do
    %w[prepared claimed installed].each do |state|
      with_item do |item, actor|
        claim = claim_in_state(item, state)
        before_claim = claim.reload.attributes
        before_item = item.reload.attributes
        before_syncs = item.syncs.pluck(:id)

        assert_enqueued_with(job: SimplefinConnectionUpdateJob, args: [ { family_id: item.family_id, claim_id: claim.id } ]) do
          Command.retry_later(item, claim_id: claim.id, actor: actor)
        end

        arguments = enqueued_jobs.last.fetch(:args).sole
        assert_equal item.family_id, arguments.fetch("family_id")
        assert_equal claim.id, arguments.fetch("claim_id")
        refute arguments.key?("setup_token")
        refute arguments.key?("old_simplefin_item_id")
        assert_equal before_claim, claim.reload.attributes
        assert_equal before_item, item.reload.attributes
        assert_equal before_syncs, item.syncs.pluck(:id)
      end
    end
  end

  test "claiming uncertain and cancelled claims cannot be retried" do
    %w[claiming uncertain cancelled].each do |state|
      with_item do |item, actor|
        claim = claim_in_state(item, state == "cancelled" ? "prepared" : state)
        Command.cancel(item, claim_id: claim.id, actor: actor) if state == "cancelled"
        before = claim.reload.attributes

        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) { Command.retry_later(item, claim_id: claim.id, actor: actor) }
        end

        assert_equal before, claim.reload.attributes
        assert_empty item.syncs
      end
    end
  end

  test "installed recovery never replaces a completed failed stale running cancelled or missing original Sync" do
    %w[completed failed stale syncing cancelled missing expired_pending].each do |status|
      with_item do |item, actor|
        claim = claim_in_state(item, "installed")
        sync = item.syncs.find(claim.sync_id)
        case status
        when "cancelled" then sync.update_columns(cancel_requested_at: Time.current)
        when "missing" then sync.destroy!
        when "expired_pending" then sync.update_columns(created_at: (Sync::STALE_AFTER + 1.minute).ago)
        else sync.update_columns(status: status)
        end
        before = claim.reload.attributes
        ids = item.syncs.pluck(:id)

        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) { Command.retry_later(item, claim_id: claim.id, actor: actor) }
        end

        assert_equal before, claim.reload.attributes
        assert_equal ids, item.syncs.pluck(:id)
      end
    end
  end

  test "credential ABA changes invalidate retry in every resumable state" do
    %w[prepared claimed installed].each do |state|
      with_item do |item, actor|
        claim = claim_in_state(item, state)
        original = item.reload.access_url
        revision = item.credential_revision
        item.update!(access_url: "https://example.com/intervening-credential")
        item.update!(access_url: original)
        assert_operator item.reload.credential_revision, :>, revision
        before = claim.reload.attributes

        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) { Command.retry_later(item, claim_id: claim.id, actor: actor) }
        end
        assert_equal before, claim.reload.attributes
      end
    end
  end

  test "cancellation retains encrypted evidence and immutable actor time and prior-state audit" do
    %w[prepared claiming claimed uncertain].each do |state|
      with_item do |item, actor|
        claim = claim_in_state(item, state)
        original_request = claim.request.deep_dup
        original_expected = claim.expected.deep_dup
        original_response = claim.response.deep_dup
        before_item = item.reload.attributes

        assert_no_enqueued_jobs { Command.cancel(item, claim_id: claim.id, actor: actor) }

        assert claim.reload.cancelled?
        assert_equal actor.id, claim.cancelled_by_id
        assert claim.cancelled_at.present?
        assert_equal state, claim.cancelled_from_state
        assert_equal "user_cancelled", claim.cancellation_reason
        assert_equal original_request, claim.request
        assert_equal original_expected, claim.expected
        assert_equal original_response, claim.response
        assert_provider_column_encrypted(claim, :request, original_request.fetch("setup_token"))
        assert_provider_column_encrypted(claim, :response, RESPONSE_URL) if state == "claimed"
        assert_equal before_item, item.reload.attributes
        audit = claim.attributes

        another_admin = create_actor(item.family, role: "admin")
        Command.cancel(item, claim_id: claim.id, actor: another_admin)
        assert_equal audit, claim.reload.attributes
        assert_raises(Fence::OwnershipChanged) do
          SimplefinConnectionUpdateJob.perform_now(claim_id: claim.id, family_id: item.family_id)
        end
        assert_raises(Command::ReauthorizationRequired) do
          Command.prepare(item, setup_token: original_request.fetch("setup_token"))
        end
        assert_equal audit, claim.reload.attributes
        assert_empty item.syncs
      end
    end
  end

  test "installed credentials cannot be cancelled as an outstanding journal request" do
    with_item do |item, actor|
      claim = claim_in_state(item, "installed")
      before_claim = claim.reload.attributes
      before_item = item.reload.attributes
      sync_id = claim.sync_id

      assert_no_enqueued_jobs do
        assert_raises(Fence::OwnershipChanged) { Command.cancel(item, claim_id: claim.id, actor: actor) }
      end

      assert_equal before_claim, claim.reload.attributes
      assert_equal before_item, item.reload.attributes
      assert_equal sync_id, item.syncs.sole.id
    end
  end

  test "journal cancellation works after migration ownership changes without changing legacy credentials" do
    %w[quiescing active retired].each do |state|
      with_item do |item, actor|
        claim = claim_in_state(item, "claimed")
        control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
          legacy_type: "SimplefinItem", legacy_id: item.id, state: state)
        before_item = item.reload.attributes
        before_control = control.reload.attributes

        assert_no_enqueued_jobs do
          assert_raises(Fence::OwnershipChanged) { Command.retry_later(item, claim_id: claim.id, actor: actor) }
          Command.cancel(item, claim_id: claim.id, actor: actor)
        end

        assert claim.reload.cancelled?
        assert_equal({ "access_url" => RESPONSE_URL }, claim.response)
        assert_equal before_item, item.reload.attributes
        assert_equal before_control, control.reload.attributes
      end
    end
  end

  test "fresh actor authorization rejects a stale demoted inactive moved or deleted administrator" do
    %i[demoted inactive moved deleted].each do |change|
      with_item do |item, actor|
        claim = claim_in_state(item, "prepared")
        foreign = Family.create!(name: "Foreign recovery actor") if change == :moved
        case change
        when :demoted then User.where(id: actor.id).update_all(role: "member")
        when :inactive then User.where(id: actor.id).update_all(active: false)
        when :moved then User.where(id: actor.id).update_all(family_id: foreign.id)
        when :deleted then actor.delete
        end
        before = claim.reload.attributes

        assert_no_enqueued_jobs do
          assert_raises(Command::Unauthorized) { Command.retry_later(item, claim_id: claim.id, actor: actor) }
          assert_raises(Command::Unauthorized) { Command.cancel(item, claim_id: claim.id, actor: actor) }
        end

        assert_equal before, claim.reload.attributes
      ensure
        User.where(id: actor&.id).update_all(family_id: item.family_id) if change == :moved && item
        foreign&.destroy!
      end
    end
  end

  test "cancelling a retained claim releases the actual quiesced migration gate without reviving queued work" do
    with_item do |item, actor|
      claim = claim_in_state(item, "claimed")
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id, state: "quiescing")
      Fence.with_exclusive(item) do |current|
        assert_raises(ProviderCredentialClaim::Pending) { ProviderCredentialClaim.assert_settled_for!(current) }
      end

      Command.cancel(item, claim_id: claim.id, actor: actor)

      Fence.with_exclusive(item) do |current|
        assert ProviderCredentialClaim.assert_settled_for!(current)
      end
      audit = claim.reload.attributes
      before_item = item.reload.attributes
      control.destroy!
      assert_no_enqueued_jobs do
        assert_raises(Fence::OwnershipChanged) do
          SimplefinConnectionUpdateJob.perform_now(family_id: item.family_id, claim_id: claim.id)
        end
      end
      assert_equal audit, claim.reload.attributes
      assert_equal before_item, item.reload.attributes
      assert_empty item.syncs
    end
  end

  test "installed new connections recover through the created item and original pending Sync" do
    with_item do |item, actor|
      token = Base64.strict_encode64("https://example.com/new-recovery/#{SecureRandom.uuid}")
      claim = Command.prepare_new(item.family, setup_token: token, item_name: "New recovery connection")
      claim.update!(state: "claiming")
      claim.update!(state: "claimed", response: { "access_url" => RESPONSE_URL })
      created = SyncJob.stub(:perform_later, ->(*) {}) { Command.perform(claim_id: claim.id, family_id: item.family_id) }
      sync_id = claim.reload.sync_id

      assert_enqueued_with(job: SimplefinConnectionUpdateJob, args: [ { family_id: item.family_id, claim_id: claim.id } ]) do
        Command.retry_later(created, claim_id: claim.id, actor: actor)
      end

      assert_equal claim.target_id, created.id
      assert_equal sync_id, created.syncs.sole.id
      assert_equal sync_id, claim.reload.sync_id
    end
  end

  test "recovery listing is bounded stable and scoped and exposes only safe value fields" do
    with_item do |item, actor|
      claims = Array.new(21) { claim_in_state(item, "prepared") }
      expected_ids = claims.sort_by { |claim| [ claim.created_at, claim.id ] }.reverse.map(&:id)
      other = item.family.simplefin_items.create!(name: "Other request list", access_url: "https://example.com/other-list")
      foreign_claim = claim_in_state(other, "claimed")

      page = Command.recovery_requests(item, actor: actor)
      assert_equal expected_ids.first(20), page.requests.map(&:id)
      assert_equal expected_ids[19], page.next_cursor
      page.requests.each do |request|
        assert_equal %i[can_cancel can_retry created_at id state], request.to_h.keys.sort
        assert request.can_retry
        assert request.can_cancel
        refute request.respond_to?(:request)
        refute request.respond_to?(:response)
      end
      refute_includes page.requests.map(&:id), foreign_claim.id
      refute_includes page.inspect, claims.first.request.fetch("setup_token")
      refute_includes page.inspect, RESPONSE_URL

      older = Command.recovery_requests(item, actor: actor, before: page.next_cursor)
      assert_equal expected_ids.last(1), older.requests.map(&:id)
      assert_nil older.next_cursor
      assert_raises(ActiveRecord::RecordNotFound) do
        Command.recovery_requests(item, actor: actor, before: foreign_claim.id)
      end
    end
  end

  test "recovery capabilities reflect current source ownership and omit cancelled history" do
    with_item do |item, actor|
      prepared = claim_in_state(item, "prepared")
      claiming = claim_in_state(item, "claiming")
      claimed = claim_in_state(item, "claimed")
      uncertain = claim_in_state(item, "uncertain")
      cancelled = claim_in_state(item, "prepared")
      Command.cancel(item, claim_id: cancelled.id, actor: actor)
      initial = Command.recovery_requests(item, actor: actor).requests.index_by(&:id)
      assert_equal [ true, true ], [ initial.fetch(prepared.id).can_retry, initial.fetch(claimed.id).can_retry ]
      assert_equal [ false, false ], [ initial.fetch(claiming.id).can_retry, initial.fetch(uncertain.id).can_retry ]
      refute initial.key?(cancelled.id)

      item.update!(scheduled_for_deletion: true)
      unavailable = Command.recovery_requests(item, actor: actor).requests
      assert unavailable.none?(&:can_retry)
      assert unavailable.all?(&:can_cancel)
      item.update!(scheduled_for_deletion: false)
      ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id, state: "active")
      native = Command.recovery_requests(item, actor: actor).requests
      assert native.none?(&:can_retry)
      assert native.all?(&:can_cancel)
    end
  end

  test "another item or family claim cannot be recovered through this target" do
    with_item do |item, actor|
      other = item.family.simplefin_items.create!(name: "Other target", access_url: "https://example.com/other")
      foreign = Family.create!(name: "Foreign recovery target")
      foreign_item = foreign.simplefin_items.create!(name: "Foreign", access_url: "https://example.com/foreign")
      [ claim_in_state(other, "prepared"), claim_in_state(foreign_item, "prepared") ].each do |claim|
        before = claim.attributes
        assert_no_enqueued_jobs do
          assert_raises(ActiveRecord::RecordNotFound) { Command.retry_later(item, claim_id: claim.id, actor: actor) }
          assert_raises(ActiveRecord::RecordNotFound) { Command.cancel(item, claim_id: claim.id, actor: actor) }
        end
        assert_equal before, claim.reload.attributes
      end
    ensure
      ProviderCredentialClaim.where(family_id: foreign.id).delete_all if foreign
      foreign_item&.destroy!
      foreign&.destroy!
    end
  end

  test "active credential work blocks retry and cancellation without changing the journal" do
    with_item do |item, actor|
      claim = claim_in_state(item, "claiming")
      before = claim.attributes
      with_active_writer(item) do
        assert_no_enqueued_jobs do
          assert_raises(Fence::Busy) { Command.retry_later(item, claim_id: claim.id, actor: actor) }
          assert_raises(Fence::Busy) { Command.cancel(item, claim_id: claim.id, actor: actor) }
        end
      end
      assert_equal before, claim.reload.attributes
    end
  end

  test "a retry worker can immediately install a saved result on another database session" do
    with_item do |item, actor|
      claim = claim_in_state(item, "claimed")
      delivered = nil
      delivery = lambda do |family_id:, claim_id:|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        delivered = on_another_session do
          Command.perform(claim_id: claim_id, family_id: family_id)
        end
      end

      SyncJob.stub(:perform_later, ->(*) {}) do
        SimplefinConnectionUpdateJob.stub(:perform_later, delivery) do
          Command.retry_later(item, claim_id: claim.id, actor: actor)
        end
      end

      assert_equal item.id, delivered.id
      assert claim.reload.installed?
      assert_equal RESPONSE_URL, item.reload.access_url
      assert_equal claim.sync_id, item.syncs.sole.id
    end
  end

  test "original Sync delivery happens after migration and credential session locks are released" do
    with_item do |item, _actor|
      claim = claim_in_state(item, "claimed")
      delivered_id = nil
      delivery = lambda do |sync|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        delivered_id = sync.id
        on_another_session do
          Fence.with_item(item, operation: :credentials) do |current|
            ProviderCredentialClaim.with_target_lock(target_type: "SimplefinItem", target_id: current.id) do
              ProviderCredentialClaim.with_request_lock(provider_key: "simplefin", request_fingerprint: claim.request_fingerprint) do
                assert_equal current.id, sync.syncable_id
                assert_equal RESPONSE_URL, current.access_url
              end
            end
          end
        end
      end

      SyncJob.stub(:perform_later, delivery) { Command.perform(claim_id: claim.id, family_id: item.family_id) }

      assert_equal claim.reload.sync_id, delivered_id
      assert_equal delivered_id, item.syncs.sole.id
    end
  end

  private

    def on_another_session
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      outcome = Queue.new
      key_provider = ActiveRecord::Encryption.key_provider
      worker = Thread.new do
        ActiveRecord::Encryption.with_encryption_context(key_provider: key_provider) do
          ApplicationRecord.connection_pool.with_connection { outcome << [ :ok, yield ] }
        end
      rescue Exception => error # Deliver assertion failures as well as runtime errors to the test thread.
        outcome << [ :error, error ]
      end
      status, result = Timeout.timeout(5) { outcome.pop }
      raise result if status == :error
      result
    ensure
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end

    def claim_in_state(item, state)
      token = Base64.strict_encode64("https://example.com/recovery/#{SecureRandom.uuid}")
      claim = Command.prepare(item, setup_token: token)
      claim.update!(state: "claiming") unless state == "prepared"
      if state == "uncertain"
        claim.update!(state: "uncertain")
      elsif %w[claimed installed].include?(state)
        claim.update!(state: "claimed", response: { "access_url" => RESPONSE_URL })
      end
      if state == "installed"
        SyncJob.stub(:perform_later, ->(*) {}) { Command.perform(claim_id: claim.id, family_id: item.family_id) }
      end
      claim.reload
    end

    def create_actor(family, role: "admin")
      User.create!(family: family, email: "recovery-#{SecureRandom.hex(6)}@example.com",
        first_name: "Recovery", last_name: "Administrator", role: role, password: "recovery-test-password")
    end

    def with_active_writer(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Fence.with_item(item, operation: :credentials) do
            ProviderCredentialClaim.with_target_lock(target_type: "SimplefinItem", target_id: item.id) do
              entered << true
              release.pop
            end
          end
        end
      rescue => error
        entered << error
      end
      result = Timeout.timeout(5) { entered.pop }
      raise result if result.is_a?(Exception)
      yield
    ensure
      release << true if release
      worker&.join(5)
      worker&.kill if worker&.alive?
      worker&.join
    end

    def with_item
      with_provider_encryption do
        family = Family.create!(name: "SimpleFIN recovery commands")
        item = family.simplefin_items.create!(name: "SimpleFIN", access_url: "https://example.com/original")
        actor = create_actor(family)
        yield item, actor
      ensure
        if family&.persisted?
          ProviderCredentialClaim.where(family_id: family.id).delete_all
          ProviderMigrationControl.where(family_id: family.id).delete_all
          family.simplefin_items.reload.each(&:destroy!)
          family.destroy!
        end
      end
    end
end
