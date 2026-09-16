require "test_helper"
require "timeout"
require_relative "../../support/provider_ingestion_test_helper"

class SimplefinItem::ConnectionUpdateTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Command = SimplefinItem::ConnectionUpdate
  Fence = Provider::AccountData::LegacyWriterFence
  CLAIM_URL = "https://example.com/private-single-use-claim".freeze
  ACCESS_URL = "https://private-user:private-password@example.com/claimed-access".freeze

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "preparation encrypts claim inputs before a queue payload containing only IDs is created" do
    with_item do |family, item|
      token = setup_token
      before = item.attributes
      claim = Command.prepare(item, setup_token: token)

      assert claim.persisted?
      assert_equal family.id, claim.family_id
      assert claim.prepared?
      assert_equal item.id, claim.target_id
      assert_equal token, claim.request.fetch("setup_token")
      assert_equal item.credential_revision, claim.expected.fetch("credential_revision")
      assert_provider_column_encrypted(claim, :request, token)
      assert_provider_column_encrypted(claim, :expected, item.id)
      assert_equal before, item.reload.attributes
      stored = ApplicationRecord.connection.select_value(
        ProviderCredentialClaim.where(id: claim.id).select(Arel.sql("row_to_json(provider_credential_claims)::text")).to_sql)
      refute_includes stored, token
      refute_includes stored, claim_url
      refute_includes stored, item.access_url

      assert_enqueued_with(job: SimplefinConnectionUpdateJob, args: [ { family_id: family.id, claim_id: claim.id } ]) do
        SimplefinConnectionUpdateJob.perform_later(family_id: family.id, claim_id: claim.id)
      end
      arguments = enqueued_jobs.last.fetch(:args).sole
      assert_equal family.id, arguments.fetch("family_id")
      assert_equal claim.id, arguments.fetch("claim_id")
      refute arguments.key?("setup_token")
      refute arguments.key?("old_simplefin_item_id")
      assert_empty item.syncs
    end
  end

  test "successful claim and explicit replay make one POST and retain the same committed Sync" do
    with_item do |family, item|
      claim = Command.prepare(item, setup_token: setup_token)
      posted = stub_claim
      scheduled = []
      enqueue = lambda do |sync|
        assert_equal 0, ApplicationRecord.connection.open_transactions
        assert_equal item.id, sync.syncable_id
        assert_equal "SimplefinItem", sync.syncable_type
        assert sync.persisted?
        assert sync.pending?
        assert_equal ACCESS_URL, item.reload.access_url
        scheduled << sync.id
      end

      VCR.turned_off do
        SyncJob.stub(:perform_later, enqueue) do
          assert_equal item.id, Command.perform(claim_id: claim.id, family_id: family.id).id
          original_sync = item.syncs.sole
          assert_equal item.id, Command.perform(claim_id: claim.id, family_id: family.id).id
          assert_equal original_sync.id, item.syncs.reload.sole.id
        end
      end

      assert_requested posted, times: 1
      assert_equal ACCESS_URL, item.reload.access_url
      assert_equal [ item.syncs.sole.id ], scheduled.uniq
      assert claim.reload.installed?
      assert_equal item.syncs.sole.id, claim.sync_id
      assert_equal item.credential_revision, claim.installed_revision
      assert_provider_column_encrypted(claim, :response, ACCESS_URL)
    end
  end

  test "a saved claim response resumes after installation SQL rolls back without another POST" do
    with_item do |family, item|
      claim = Command.prepare(item, setup_token: setup_token)
      original_url = item.access_url
      original_revision = item.credential_revision
      posted = stub_claim
      issued_writes = []
      callback = lambda do |record|
        next unless record.id == item.id && record.access_url == ACCESS_URL
        issued_writes << SimplefinItem.find(item.id).access_url
        raise IOError, "Private installation callback"
      end
      SimplefinItem.set_callback(:update, :after, callback)
      begin
        VCR.turned_off do
          assert_no_enqueued_jobs do
            assert_raises(IOError) { Command.perform(claim_id: claim.id, family_id: family.id) }
          end
        end
      ensure
        SimplefinItem.skip_callback(:update, :after, callback)
      end

      assert_equal [ ACCESS_URL ], issued_writes
      assert_equal original_url, item.reload.access_url
      assert_equal original_revision, item.credential_revision
      assert_empty item.syncs
      assert claim.reload.claimed?
      assert_equal({ "access_url" => ACCESS_URL }, claim.response)
      assert_nil claim.sync_id
      assert_provider_column_encrypted(claim, :response, ACCESS_URL)

      VCR.turned_off do
        assert_enqueued_jobs 1, only: SyncJob do
          assert_equal item.id, Command.perform(claim_id: claim.id, family_id: family.id).id
        end
      end
      assert_requested posted, times: 1
      assert claim.reload.installed?
      assert_equal item.syncs.sole.id, claim.sync_id
    end
  end

  test "an abandoned claiming attempt becomes uncertain and cannot POST again" do
    with_item do |family, item|
      claim = Command.prepare(item, setup_token: setup_token)
      claim.update!(state: "claiming")
      posted = stub_claim
      original = item.reload.attributes

      VCR.turned_off do
        2.times do
          assert_no_enqueued_jobs do
            assert_raises(Command::ReauthorizationRequired) { Command.perform(claim_id: claim.id, family_id: family.id) }
          end
        end
      end

      assert claim.reload.uncertain?
      assert_empty claim.response
      assert_not_requested posted
      assert_equal original, item.reload.attributes
      assert_empty item.syncs
    end
  end

  test "credential revision detects both drift and an ABA restoration before the first POST" do
    [ false, true ].each do |restore|
      with_item do |family, item|
        claim = Command.prepare(item, setup_token: setup_token)
        original_url = item.access_url
        original_revision = item.credential_revision
        item.update!(access_url: "https://example.com/intervening-credential")
        item.update!(access_url: original_url) if restore
        before = item.reload.attributes
        assert_operator item.credential_revision, :>, original_revision
        posted = stub_claim

        VCR.turned_off do
          assert_no_enqueued_jobs do
            assert_raises(Fence::OwnershipChanged) { Command.perform(claim_id: claim.id, family_id: family.id) }
          end
        end

        assert_not_requested posted
        assert claim.reload.prepared?
        assert_equal before, item.reload.attributes
        assert_empty item.syncs
      end
    end
  end

  test "ownership epoch deletion flags and a removed target deny the claim before HTTP" do
    %i[ownership epoch deletion_flag removed].each do |change|
      with_item do |family, item|
        claim = Command.prepare(item, setup_token: setup_token)
        case change
        when :ownership
          ProviderMigrationControl.create!(family: family, provider_key: "simplefin",
            legacy_type: "SimplefinItem", legacy_id: item.id, state: "active")
        when :epoch
          ProviderMigrationControl.create!(family: family, provider_key: "simplefin",
            legacy_type: "SimplefinItem", legacy_id: item.id, writer_epoch: 1)
        when :deletion_flag then item.update!(scheduled_for_deletion: true)
        when :removed then item.destroy!
        end
        posted = stub_claim

        VCR.turned_off do
          assert_no_enqueued_jobs do
            assert_raises(Fence::OwnershipChanged) { Command.perform(claim_id: claim.id, family_id: family.id) }
          end
        end

        assert_not_requested posted
        assert claim.reload.prepared?
        assert_empty Sync.where(syncable_type: "SimplefinItem", syncable_id: claim.target_id)
      end
    end
  end

  test "a response cannot install after credential ABA ownership or deletion changes during HTTP" do
    %i[credentials aba ownership epoch deletion_flag removed].each do |change|
      with_item do |family, item|
        claim = Command.prepare(item, setup_token: setup_token)
        original_url = item.access_url
        posted = stub_claim do
          case change
          when :credentials, :aba
            item.update!(access_url: "https://example.com/intervening-credential")
            item.update!(access_url: original_url) if change == :aba
          when :ownership
            ProviderMigrationControl.create!(family: family, provider_key: "simplefin",
              legacy_type: "SimplefinItem", legacy_id: item.id, state: "active")
          when :epoch
            ProviderMigrationControl.create!(family: family, provider_key: "simplefin",
              legacy_type: "SimplefinItem", legacy_id: item.id, writer_epoch: 1)
          when :deletion_flag then item.update!(scheduled_for_deletion: true)
          when :removed then item.delete
          end
        end

        VCR.turned_off do
          assert_no_enqueued_jobs do
            assert_raises(Fence::OwnershipChanged) { Command.perform(claim_id: claim.id, family_id: family.id) }
          end
        end

        assert_requested posted, times: 1
        assert claim.reload.claimed?
        assert_equal({ "access_url" => ACCESS_URL }, claim.response)
        assert_nil claim.sync_id
        current = SimplefinItem.find_by(id: item.id)
        refute_equal ACCESS_URL, current.access_url if current
        assert_empty Sync.where(syncable_type: "SimplefinItem", syncable_id: item.id)
      end
    end
  end

  test "one setup token cannot be rebound to another item family or connect operation" do
    with_item do |family, item|
      claim = Command.prepare(item, setup_token: setup_token)
      other = family.simplefin_items.create!(name: "Other", access_url: "https://example.com/other")
      foreign = Family.create!(name: "Foreign claim owner")
      foreign_item = foreign.simplefin_items.create!(name: "Foreign", access_url: "https://example.com/foreign")
      posted = stub_claim

      assert_equal claim.id, Command.prepare(item, setup_token: setup_token).id
      assert_raises(Fence::OwnershipChanged) { Command.prepare(other, setup_token: setup_token) }
      assert_raises(Fence::OwnershipChanged) { Command.prepare(foreign_item, setup_token: setup_token) }
      assert_raises(Fence::OwnershipChanged) { Command.prepare_new(family, setup_token: setup_token) }
      assert_raises(ActiveRecord::RecordNotFound) { Command.perform(claim_id: claim.id, family_id: foreign.id) }
      assert_equal 1, ProviderCredentialClaim.where(request_fingerprint: claim.request_fingerprint).count
      assert_not_requested posted
    ensure
      foreign_item&.destroy!
      foreign&.destroy!
    end
  end

  test "a competing credential target session denies work without consuming the prepared token" do
    with_item do |family, item|
      claim = Command.prepare(item, setup_token: setup_token)
      posted = stub_claim
      with_target_lock(item) do
        assert_raises(Fence::Busy) { Command.perform(claim_id: claim.id, family_id: family.id) }
        assert_raises(Fence::Busy) do
          SimplefinItem::LegacyAccess.with_item(item) { flunk "A credential consumer entered a competing session" }
        end
      end
      assert claim.reload.prepared?
      assert_not_requested posted
      assert_empty item.syncs
    end
  end

  test "unconfigured encryption prevents preparing or consuming a claim before HTTP" do
    with_item do |family, item|
      posted = stub_claim
      ActiveRecordEncryptionConfig.stub(:ready?, false) do
        assert_no_difference "ProviderCredentialClaim.count" do
          assert_raises(ActiveRecord::RecordInvalid) { Command.prepare(item, setup_token: setup_token) }
          assert_raises(ActiveRecord::RecordInvalid) { Command.prepare_new(family, setup_token: setup_token) }
        end
      end
      claim = Command.prepare(item, setup_token: setup_token)
      ActiveRecordEncryptionConfig.stub(:ready?, false) do
        assert_raises(ActiveRecord::RecordInvalid) { Command.perform(claim_id: claim.id, family_id: family.id) }
      end
      assert claim.reload.prepared?
      assert_not_requested posted
      assert_empty item.syncs
    end
  end

  test "preparing a new connection reserves its context without an empty item before the claim succeeds" do
    with_item(existing: false) do |family, _item|
      claim = Command.prepare_new(family, setup_token: setup_token, item_name: "New SimpleFIN")
      assert claim.persisted?
      assert_equal "connect", claim.operation
      assert_empty family.simplefin_items
      posted = stub_claim do
        assert_empty family.simplefin_items
      end
      SyncJob.stubs(:perform_later)

      VCR.turned_off do
        created = Command.perform(claim_id: claim.id, family_id: family.id)
        assert_equal claim.target_id, created.id
        assert_equal family.id, created.family_id
        assert_equal "New SimpleFIN", created.name
        assert_equal ACCESS_URL, created.access_url
        assert_equal created.id, family.simplefin_items.reload.sole.id
        assert_equal created.id, Command.perform(claim_id: claim.id, family_id: family.id).id
        assert_equal 1, created.syncs.count
      end

      assert_requested posted, times: 1
    end
  end

  test "an ambiguous new connection claim leaves no empty item and cannot retry the POST" do
    with_item(existing: false) do |family, _item|
      claim = Command.prepare_new(family, setup_token: setup_token)
      posted = stub_request(:post, claim_url).to_raise(Net::ReadTimeout.new("Private claim timeout"))

      VCR.turned_off do
        assert_no_enqueued_jobs do
          assert_raises(Provider::Simplefin::SimplefinError) { Command.perform(claim_id: claim.id, family_id: family.id) }
          assert_raises(Command::ReauthorizationRequired) { Command.perform(claim_id: claim.id, family_id: family.id) }
        end
      end

      assert claim.reload.uncertain?
      assert_empty family.simplefin_items
      assert_empty Sync.where(syncable_type: "SimplefinItem", syncable_id: claim.target_id)
      assert_requested posted, times: 1
    end
  end

  private

    def setup_token
      Base64.strict_encode64(claim_url)
    end

    def claim_url
      @claim_url || CLAIM_URL
    end

    def stub_claim(&during_request)
      stub_request(:post, claim_url).to_return do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        during_request&.call
        { status: 200, body: ACCESS_URL }
      end
    end

    def with_target_lock(item)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      entered, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ProviderCredentialClaim.with_target_lock(target_type: "SimplefinItem", target_id: item.id) do
            entered << true
            release.pop
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

    def with_item(existing: true)
      with_provider_encryption do
        previous_url = @claim_url
        @claim_url = "#{CLAIM_URL}/#{SecureRandom.uuid}"
        family = Family.create!(name: "SimpleFIN durable credential claim")
        item = family.simplefin_items.create!(name: "Original SimpleFIN", access_url: "https://example.com/original") if existing
        yield family, item
      ensure
        if family&.persisted?
          ProviderCredentialClaim.where(family_id: family.id).delete_all
          ProviderMigrationControl.where(family_id: family.id).delete_all
          family.simplefin_items.reload.each(&:destroy!)
          family.destroy!
        end
        @claim_url = previous_url
      end
    end
end
