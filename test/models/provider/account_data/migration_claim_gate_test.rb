require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Provider::AccountData::MigrationClaimGateTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Claim = ProviderCredentialClaim
  Copier = Provider::AccountData::MigrationCopier
  Preparation = Provider::AccountData::MigrationPreparation
  Fence = Provider::AccountData::LegacyWriterFence

  %w[prepared claiming claimed].each do |state|
    test "#{state} credentials stop quiescence before any control or native connection exists" do
      with_source do |item, copier|
        claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
        advance_claim(claim, state)
        before = claim.reload.attributes

        assert_raises(Claim::Pending) { copier.run_quiesced }
        assert_raises(Claim::Pending) do
          Preparation.new(provider_key: "simplefin", legacy_item_id: item.id, family: item.family).run
        end

        assert_not ProviderMigrationControl.exists?(legacy_type: "SimplefinItem", legacy_id: item.id)
        assert_not ProviderConnection.exists?(family_id: item.family_id)
        assert_equal before, claim.reload.attributes
        assert_equal "https://example.com/original", item.reload.access_url
      end
    end
  end

  test "an existing legacy control is unchanged when its outstanding claim blocks copy" do
    with_source do |item, copier|
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
      control = ProviderMigrationControl.create!(family: item.family, provider_key: "simplefin",
        legacy_type: "SimplefinItem", legacy_id: item.id, state: "legacy")
      before = control.reload.attributes

      assert_raises(Claim::Pending) { copier.run_quiesced(restart: true) }

      assert_equal before, control.reload.attributes
      assert claim.reload.prepared?
      assert_nil control.provider_connection_id
      assert_not ProviderConnection.exists?(family_id: item.family_id)
    end
  end

  test "retained verification and the verified-copy preparation shortcut reject an outstanding old claim" do
    with_source do |item, copier|
      control = finish_copy(copier)
      # Model an earlier deployment that paused copying after a request was
      # authorized but before executing it. This is an unconsumed journal row,
      # not accepted migration or credential evidence.
      token = setup_token
      claim = Claim.create!(family: item.family, provider_key: "simplefin", operation: "reconnect",
        target_type: "SimplefinItem", target_id: item.id,
        request_fingerprint: Digest::SHA256.hexdigest("simplefin:claim:v1\0#{Base64.strict_decode64(token)}"),
        request: { "setup_token" => token, "item_name" => nil },
        expected: { "family_id" => item.family_id, "item_id" => item.id,
          "credential_revision" => item.reload.credential_revision, "writer_epoch" => control.writer_epoch }, response: {})
      before_control = control.reload.attributes
      before_batches = control.provider_connection.ingestion_batches.order(:id).map(&:attributes)

      assert_raises(Claim::Pending) do
        copier.verify_retained_quiesced_page(family: item.family)
      end
      assert_raises(Claim::Pending) do
        Preparation.new(provider_key: "simplefin", legacy_item_id: item.id, family: item.family).run
      end

      assert_equal before_control, control.reload.attributes
      assert_equal before_batches, control.provider_connection.ingestion_batches.order(:id).map(&:attributes)
      assert_empty control.preparation_state
      assert claim.reload.prepared?
    end
  end

  test "terminal ambiguity remains retained but does not pretend an exchange is still publishable" do
    with_source do |item, copier|
      claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
      claim.update!(state: "claiming")
      claim.update!(state: "uncertain")
      before = claim.reload.attributes

      control = finish_copy(copier)

      assert control.quiescing?
      assert control.provider_connection.disabled?
      assert_equal before, claim.reload.attributes
      assert_empty claim.response
      assert_equal "https://example.com/original", item.reload.access_url
    end
  end

  test "explicitly cancelled claims permit copying and retained admission without discarding their results" do
    %w[prepared claiming claimed uncertain].each do |previous_state|
      with_source do |item, copier|
        claim = SimplefinItem::ConnectionUpdate.prepare(item, setup_token: setup_token)
        advance_claim(claim, previous_state)
        claim.update!(state: "uncertain") if previous_state == "uncertain"
        claim.update!(state: "cancelled", cancelled_at: Time.current, cancelled_by_id: SecureRandom.uuid,
          cancelled_from_state: previous_state, cancellation_reason: "user_cancelled")
        before = claim.reload.attributes

        control = finish_copy(copier)
        copier.verify_retained_quiesced_page(family: item.family)
        Preparation.new(provider_key: "simplefin", legacy_item_id: item.id, family: item.family).run

        assert control.reload.quiescing?
        assert control.provider_connection.disabled?
        assert_equal before, claim.reload.attributes
        assert_equal "https://example.com/original", item.reload.access_url
        assert_nil claim.installed_revision
        assert_nil claim.sync_id
        if previous_state == "claimed"
          assert_equal "https://example.com/confirmed", claim.response.fetch("access_url")
        else
          assert_empty claim.response
        end
      end
    end
  end

  test "a settled check without the exclusive permit cannot authorize migration" do
    with_source do |item, _copier|
      assert_raises(Fence::InvalidSource) { Claim.assert_settled_for!(item) }
      Fence.with_exclusive(item) { assert Claim.assert_settled_for!(item) }
    end
  end

  private
    def setup_token
      Base64.strict_encode64("https://example.com/claim/#{SecureRandom.uuid}")
    end

    def advance_claim(claim, state)
      claim.update!(state: "claiming") unless state == "prepared"
      claim.update!(state: "claimed", response: { "access_url" => "https://example.com/confirmed" }) if state == "claimed"
    end

    def finish_copy(copier)
      5.times do
        control = copier.run_quiesced
        return control if control.high_water_mark["phase"] == "verified"
      end
      flunk "Empty-account quiesced copy did not finish"
    end

    def with_source
      with_provider_encryption do
        DebugLogEntry.stubs(:capture)
        family = Family.create!(name: "Claim migration gate")
        item = SimplefinItem.create!(family: family, name: "SimpleFIN", access_url: "https://example.com/original")
        copier = Copier.new(provider_key: "simplefin", legacy_item_id: item.id, batch_size: 1)
        yield item, copier
      ensure
        control = ProviderMigrationControl.find_by(legacy_type: "SimplefinItem", legacy_id: item.id) if item
        connection = control&.provider_connection
        connection&.provider_sync_checkpoints&.delete_all
        ProviderMigrationAccountBinding.where(family_id: control.family_id,
          provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all if control
        connection&.ingestion_batches&.delete_all
        control&.provider_migration_mappings&.delete_all
        control&.delete
        connection&.destroy!
        item&.reload&.destroy!
        family&.destroy!
      end
    end
end
