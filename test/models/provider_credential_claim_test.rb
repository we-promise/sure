require "test_helper"
require_relative "../support/provider_ingestion_test_helper"

class ProviderCredentialClaimTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  self.use_transactional_tests = false

  Claim = ProviderCredentialClaim

  test "intent result and installation survive reload with encrypted immutable documents" do
    with_claim do |claim|
      assert claim.reload.prepared?
      assert_empty claim.response
      assert_provider_column_encrypted(claim, :request, "private-setup-token")
      assert_provider_column_encrypted(claim, :expected, "credential_revision")

      claim.update!(state: "claiming")
      assert Claim.find(claim.id).claiming?
      claim.update!(state: "claimed", response: { "access_url" => "https://user:private-access@example.com/access" })
      assert_provider_column_encrypted(claim, :response, "private-access")
      assert_equal "https://user:private-access@example.com/access", Claim.find(claim.id).response.fetch("access_url")

      sync_id = SecureRandom.uuid
      claim.update!(state: "installed", installed_revision: 4, sync_id: sync_id)
      assert claim.reload.installed?
      assert_equal 4, claim.installed_revision
      assert_equal sync_id, claim.sync_id
      refute_includes claim.inspect, "private-setup-token"
      refute_includes claim.inspect, "private-access"
    end
  end

  test "an interrupted claim cannot be returned to prepared or installed without a result" do
    with_claim do |claim|
      claim.update!(state: "claiming")
      assert_invalid_update(claim, state: "installed", installed_revision: 4)
      assert_sql_rejected { Claim.where(id: claim.id).update_all(state: "installed", installed_revision: 4) }
      claim.reload.update!(state: "uncertain")

      %w[prepared claiming claimed installed].each do |state|
        assert_invalid_update(claim, state: state)
        assert_sql_rejected { Claim.where(id: claim.id).update_all(state: state) }
        assert claim.reload.uncertain?
      end
    end
  end

  test "preparation identity and documents cannot be changed through normal or direct writes" do
    with_claim do |claim|
      changes = [
        { target_id: SecureRandom.uuid }, { operation: "connect" },
        { request_fingerprint: Digest::SHA256.hexdigest("another request") },
        { request: claim.request.merge("setup_token" => "replacement-private-token") },
        { expected: claim.expected.merge("credential_revision" => 99) }
      ]
      changes.each do |attributes|
        original = claim.reload.attributes
        assert_invalid_update(claim, **attributes)
        assert_sql_rejected { Claim.where(id: claim.id).update_all(attributes) }
        assert_equal original, claim.reload.attributes
      end
    end
  end

  test "confirmation cannot be fabricated at insertion or changed after its first commit" do
    with_claim do |claim|
      copy = Claim.new(claim.attributes.except("id", "created_at", "updated_at", "lock_version").merge(
        "request_fingerprint" => Digest::SHA256.hexdigest("fabricated confirmation"),
        "state" => "claimed", "response" => { "access_url" => "https://example.com/fabricated" }))
      assert_not copy.valid?
      assert_sql_rejected { copy.save!(validate: false) }

      claim.update!(state: "claiming")
      claim.update!(state: "claimed", response: { "access_url" => "https://example.com/confirmed" })
      assert_invalid_update(claim, response: { "access_url" => "https://example.com/replacement" })
      assert_sql_rejected do
        Claim.where(id: claim.id).update_all(response: { "access_url" => "https://example.com/replacement" })
      end
      assert_equal "https://example.com/confirmed", claim.reload.response.fetch("access_url")
    end
  end

  test "installation revision and original Sync are retained independently of live Sync rows" do
    with_claim do |claim|
      claim.update!(state: "claiming")
      claim.update!(state: "claimed", response: { "access_url" => "https://example.com/confirmed" })
      claim.update!(state: "installed", installed_revision: 4)
      sync_id = SecureRandom.uuid
      claim.update!(sync_id: sync_id)
      assert_equal sync_id, claim.reload.sync_id
      assert_not Sync.exists?(id: sync_id)

      [ { installed_revision: 5 }, { sync_id: SecureRandom.uuid }, { sync_id: nil }, { state: "claimed" } ].each do |attributes|
        assert_invalid_update(claim, **attributes)
        assert_sql_rejected { Claim.where(id: claim.id).update_all(attributes) }
        assert claim.reload.installed?
        assert_equal 4, claim.installed_revision
        assert_equal sync_id, claim.sync_id
      end
    end
  end

  %w[prepared claiming claimed uncertain].each do |previous_state|
    test "#{previous_state} cancellation retains the encrypted exchange and historical audit" do
      with_claim do |claim|
        advance_to_cancellable_state(claim, previous_state)
        original_documents = claim.reload.attributes_before_type_cast.slice("request", "expected", "response")
        audit = cancellation_attributes(previous_state)

        claim.update!(audit)

        assert claim.reload.cancelled?
        assert_equal previous_state, claim.cancelled_from_state
        assert_equal audit.fetch(:cancelled_by_id), claim.cancelled_by_id
        assert_equal "user_cancelled", claim.cancellation_reason
        assert_not_nil claim.cancelled_at
        assert_not User.exists?(id: claim.cancelled_by_id)
        assert_equal original_documents, claim.attributes_before_type_cast.slice("request", "expected", "response")
        if previous_state == "claimed"
          assert_equal "https://example.com/confirmed", claim.response.fetch("access_url")
        else
          assert_empty claim.response
        end
        assert_nil claim.installed_revision
        assert_nil claim.sync_id

        # A no-op later save may not rewrite the retained audit or documents.
        before = claim.attributes.except("updated_at", "lock_version")
        claim.touch
        assert_equal before, claim.reload.attributes.except("updated_at", "lock_version")
      end
    end
  end

  test "direct SQL permits a complete cancellation only from its actual prior state" do
    %w[prepared claiming claimed uncertain].each do |previous_state|
      with_claim do |claim|
        advance_to_cancellable_state(claim, previous_state)
        original_response = claim.reload.response
        audit = cancellation_attributes(previous_state)
        wrong_prior = previous_state == "prepared" ? "claiming" : "prepared"
        assert_sql_rejected { Claim.where(id: claim.id).update_all(audit.merge(cancelled_from_state: wrong_prior)) }
        assert_equal previous_state, claim.reload.state

        Claim.where(id: claim.id).update_all(audit)

        assert claim.reload.cancelled?
        assert_equal previous_state, claim.cancelled_from_state
        assert_equal original_response, claim.response
      end
    end
  end

  test "cancellation requires complete fixed audit fields and cannot attach them early" do
    with_claim do |claim|
      audit = cancellation_attributes("prepared")
      [ { cancelled_at: nil }, { cancelled_by_id: nil }, { cancelled_from_state: nil },
        { cancellation_reason: nil }, { cancellation_reason: "automatic_retry" },
        { cancelled_from_state: "installed" }, { installed_revision: 0 }, { sync_id: SecureRandom.uuid } ].each do |invalid|
        assert_invalid_update(claim, **audit.merge(invalid))
        assert_sql_rejected { Claim.where(id: claim.id).update_all(audit.merge(invalid)) }
      end
      assert_invalid_update(claim, **audit.merge(cancelled_at: "invalid time"))
      assert_invalid_update(claim, **audit.merge(cancelled_by_id: "invalid UUID"))
      assert_sql_rejected do
        Claim.where(id: claim.id).update_all([
          "state = ?, cancelled_at = 'infinity'::timestamp, cancelled_by_id = ?, cancelled_from_state = ?, cancellation_reason = ?",
          "cancelled", audit.fetch(:cancelled_by_id), "prepared", "user_cancelled"
        ])
      end
      Claim::CANCELLATION_ATTRIBUTES.each do |attribute|
        change = { attribute.to_sym => audit.fetch(attribute.to_sym) }
        assert_invalid_update(claim, **change)
        assert_sql_rejected { Claim.where(id: claim.id).update_all(change) }
      end
      assert claim.reload.prepared?
    end
  end

  test "cancelled disposition is terminal and its audit and result cannot be rewritten" do
    with_claim do |claim|
      advance_to_cancellable_state(claim, "claimed")
      claim.update!(cancellation_attributes("claimed"))
      original = claim.reload.attributes
      changes = [
        { cancelled_at: claim.cancelled_at + 1.second }, { cancelled_by_id: SecureRandom.uuid },
        { cancelled_from_state: "claiming" }, { cancellation_reason: nil },
        { response: {} }, { response: { "access_url" => "https://example.com/replaced" } },
        { installed_revision: 4 }, { sync_id: SecureRandom.uuid }
      ] + %w[prepared claiming claimed uncertain installed].map { |state| { state: state } }
      changes.each do |attributes|
        assert_invalid_update(claim, **attributes)
        assert_sql_rejected { Claim.where(id: claim.id).update_all(attributes) }
        assert_equal original, claim.reload.attributes
      end
    end
  end

  test "cancellation cannot discard a confirmed response or invent an unconfirmed one" do
    with_claim do |claim|
      audit = cancellation_attributes("prepared")
      fake_response = { "access_url" => "https://example.com/fabricated" }
      assert_invalid_update(claim, **audit.merge(response: fake_response))
      assert_sql_rejected { Claim.where(id: claim.id).update_all(audit.merge(response: fake_response)) }
      advance_to_cancellable_state(claim, "claimed")
      audit = cancellation_attributes("claimed")
      assert_invalid_update(claim, **audit.merge(response: {}))
      assert_sql_rejected { Claim.where(id: claim.id).update_all(audit.merge(response: {})) }
      assert claim.reload.claimed?
    end
  end

  test "installed claims and new rows cannot be cancelled" do
    with_claim do |claim|
      advance_to_cancellable_state(claim, "claimed")
      claim.update!(state: "installed", installed_revision: 4)
      audit = cancellation_attributes("installed").merge(installed_revision: nil)
      assert_invalid_update(claim, **audit)
      assert_sql_rejected { Claim.where(id: claim.id).update_all(audit) }
      assert claim.reload.installed?

      candidate = build_claim(claim.family, **cancellation_attributes("prepared"))
      assert_not candidate.valid?
      assert_sql_rejected { candidate.save!(validate: false) }
    end
  end

  test "one provider request fingerprint cannot be claimed again by a different family or target" do
    with_claim do |claim|
      other_family = Family.create!(name: "Another credential claim family")
      begin
        duplicate = build_claim(other_family, request_fingerprint: claim.request_fingerprint)
        assert_not duplicate.valid?
        assert duplicate.errors[:request_fingerprint].present?
        assert_sql_rejected(error_class: ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
        assert_equal 1, Claim.where(provider_key: "simplefin", request_fingerprint: claim.request_fingerprint).count
      ensure
        other_family.destroy!
      end
    end
  end

  test "unsupported targets document shapes and decoded byte overflow are rejected without exposing secrets" do
    with_claim do |claim|
      bad_documents = [
        [ :request, { "setup_token" => "private-only-token" } ],
        [ :request, { "setup_token" => "private-token", :item_name => "mixed keys" } ],
        [ :request, claim.request.merge("setup_token" => "private-" + "x" * Claim::MAX_DOCUMENT_BYTES) ],
        [ :expected, claim.expected.merge("family_id" => SecureRandom.uuid) ],
        [ :expected, claim.expected.merge("credential_revision" => -1) ],
        [ :expected, claim.expected.merge("writer_epoch" => -1) ],
        [ :response, { "access_url" => "https://example.com/unconfirmed" } ]
      ]
      bad_documents.each do |attribute, value|
        candidate = build_claim(claim.family)
        candidate.public_send("#{attribute}=", value)
        assert_not candidate.valid?
        assert candidate.errors[attribute].present?
        refute_includes candidate.errors.full_messages.join(" "), "private-"
      end
      candidate = build_claim(claim.family, provider_key: "up", target_type: "UpItem")
      assert_not candidate.valid?
      assert_sql_rejected { candidate.save!(validate: false) }
    end
  end

  test "a connect claim pins its preallocated identity without a fabricated legacy item" do
    with_claim(operation: "connect") do |claim|
      assert_nil claim.expected.fetch("credential_revision")
      assert_not SimplefinItem.exists?(id: claim.target_id)
      assert_equal claim.target_id, claim.expected.fetch("item_id")
      claim.update!(state: "claiming")
      claim.update!(state: "claimed", response: { "access_url" => "https://example.com/confirmed" })
      # Storage permits this transition; the command must commit the actual
      # target insertion in the same transaction as installation.
      claim.update!(state: "installed", installed_revision: 0)
      assert claim.reload.installed?
    end
  end

  test "family deletion cascades its retained claim journal" do
    with_claim do |claim|
      claim.family.destroy!
      assert_not Claim.exists?(id: claim.id)
    end
  end

  test "new advisory locks reject transactions while exact held reentry remains safe" do
    target = SecureRandom.uuid
    fingerprint = Digest::SHA256.hexdigest("same locked request")
    assert_raises(ArgumentError) do
      Claim.transaction { Claim.with_target_lock(target_type: "SimplefinItem", target_id: target) { flunk } }
    end
    assert_raises(ArgumentError) do
      Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) { flunk }
    end

    Claim.with_target_lock(target_type: "SimplefinItem", target_id: target) do
      Claim.transaction do
        assert_equal :reentered, Claim.with_target_lock(target_type: "SimplefinItem", target_id: target) { :reentered }
        assert_raises(ArgumentError) do
          Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) { flunk }
        end
      end
      Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) do
        Claim.transaction do
          Claim.with_target_lock(target_type: "SimplefinItem", target_id: target) do
            assert_equal :reentered, Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) { :reentered }
          end
          assert_raises(ArgumentError) { Claim.with_target_lock(target_type: "SimplefinItem", target_id: SecureRandom.uuid) { flunk } }
        end
      end
    end
  end

  test "competing sessions serialize both targets and the same request across different targets" do
    first_target, second_target = SecureRandom.uuid, SecureRandom.uuid
    fingerprint = Digest::SHA256.hexdigest("one remotely consumable token")
    Claim.with_target_lock(target_type: "SimplefinItem", target_id: first_target) do
      target_result = in_another_session do
        Claim.with_target_lock(target_type: "SimplefinItem", target_id: first_target) { :unexpected }
      rescue Claim::Busy
        :busy
      end
      assert_equal :busy, target_result
      Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) do
        request_result = in_another_session do
          Claim.with_target_lock(target_type: "SimplefinItem", target_id: second_target) do
            Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) { :unexpected }
          end
        rescue Claim::Busy
          :busy
        end
        assert_equal :busy, request_result
      end
    end
    # The failed request admission must also release its already-held target.
    released = in_another_session do
      Claim.with_target_lock(target_type: "SimplefinItem", target_id: second_target) do
        Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) { :released }
      end
    end
    assert_equal :released, released
  end

  test "both session locks are released after an interrupted caller" do
    target = SecureRandom.uuid
    fingerprint = Digest::SHA256.hexdigest("interrupted request")
    assert_raises(IOError) do
      Claim.with_target_lock(target_type: "SimplefinItem", target_id: target) do
        Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) { raise IOError, "interrupted" }
      end
    end
    released = in_another_session do
      Claim.with_target_lock(target_type: "SimplefinItem", target_id: target) do
        Claim.with_request_lock(provider_key: "simplefin", request_fingerprint: fingerprint) { :released }
      end
    end
    assert_equal :released, released
  end

  private
    def cancellation_attributes(previous_state)
      { state: "cancelled", cancelled_at: Time.current, cancelled_by_id: SecureRandom.uuid,
        cancelled_from_state: previous_state, cancellation_reason: "user_cancelled" }
    end

    def advance_to_cancellable_state(claim, state)
      claim.update!(state: "claiming") unless state == "prepared"
      if state == "claimed"
        claim.update!(state: "claimed", response: { "access_url" => "https://example.com/confirmed" })
      elsif state == "uncertain"
        claim.update!(state: "uncertain")
      end
    end

    def build_claim(family, operation: "reconnect", **attributes)
      target_id = SecureRandom.uuid
      Claim.new({ family: family, provider_key: "simplefin", operation: operation,
        target_type: "SimplefinItem", target_id: target_id, request_fingerprint: Digest::SHA256.hexdigest(SecureRandom.uuid),
        request: { "setup_token" => "private-setup-token", "item_name" => nil },
        expected: { "family_id" => family.id, "item_id" => target_id,
          "credential_revision" => operation == "connect" ? nil : 3, "writer_epoch" => 0 }, response: {} }.merge(attributes))
    end

    def with_claim(**attributes)
      with_provider_encryption do
        family = Family.create!(name: "Credential claim journal")
        claim = build_claim(family, **attributes)
        claim.save!
        yield claim
      ensure
        family.destroy! if family&.persisted? && Family.exists?(id: family.id)
      end
    end

    def assert_invalid_update(claim, **attributes)
      assert_raises(ActiveRecord::RecordInvalid) { claim.reload.update!(attributes) }
      claim.reload
    end

    def assert_sql_rejected(error_class: ActiveRecord::StatementInvalid)
      assert_raises(error_class) do
        Claim.transaction(requires_new: true) { yield }
      end
    end

    def in_another_session(&block)
      skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
      worker = Thread.new { ApplicationRecord.connection_pool.with_connection { block.call } }
      Timeout.timeout(5) { worker.value }
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
end
