require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Simplefin::RetainedHintTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Hint = Provider::AccountData::Simplefin::RetainedHint
  Snapshot = Ingestion::BalancePolicies::Simplefin::Snapshot

  setup do
    @now = Time.utc(2026, 9, 15, 12)
    DebugLogEntry.stubs(:capture)
    Setting.stubs(:[]).returns(nil)
    Setting.stubs(:[]).with("simplefin_cc_overpayment_detection").returns(true)
  end

  test "quiesced copy retains typed cache value and original expiry without financial writes" do
    raw = { value: :credit, expires_at: @now + 1.day }
    with_copy(raw: raw) do |context|
      original = context.copier.snapshot_for(context.mapping)
      retained = original.fetch("auxiliary_inputs").fetch(Hint::KEY)
      assert_equal raw, retained.fetch("raw_hint")
      assert_equal "present", retained.fetch("availability")
      assert_equal @now, retained.fetch("captured_at")
      assert_equal Hint.cache_key(context.source.id), retained.fetch("cache_key")
      assert_equal BigDecimal("123"), context.account.reload.balance
      assert_empty context.account.entries
      assert_empty context.external.sensitive_details.fetch("balance_policy_state", {})
      assert_equal({ "value" => "credit", "expires_at" => (@now + 1.day).iso8601(9) },
        Hint.read(connection: context.external.provider_connection, external: context.external))
    end
  end

  test "native factory consumes retained hint and live validation does not query cache or archive bytes" do
    with_copy(raw: { value: "credit", expires_at: @now + 1.day }) do |context|
      connection = context.external.provider_connection
      context.control.update!(state: "active") # Test-only admission; this is not an activation command.
      connection.update!(status: "good")
      Provider::AccountData::Registry.stubs(:fetch).with("simplefin").returns(Provider::AccountData::Simplefin)
      Provider::Simplefin.stubs(:new).returns(mock("unused SimpleFIN transport"))
      grant = Provider::AccountData::RequestGrant.new(connection)
      adapter = Provider::AccountData::Registry.build(connection, observed_at: @now, request_grant: grant)
      record = Ingestion::Record.account(external_id: context.external.external_id, name: "Card", currency: "USD",
        metadata: { runtime_external_account_id: context.external.id, runtime_identity_namespace: context.external.identity_namespace })
      captured = adapter.balance_policy_snapshot(record)
      assert_equal "retained_migration", captured.fetch("sticky_hint_source")
      assert_equal :credit, Ingestion::BalancePolicies::Simplefin.new(snapshot: captured).call(observed_balance: "-123").classification
      Rails.cache.expects(:read).with(Hint.cache_key(context.source.id)).never
      IngestionBatch.any_instance.expects(:payload).never
      assert grant.verify!
      context.mapping.update_columns(source_checksum: "v1-#{'0' * 64}")
      assert_raises(Provider::AccountData::StaleWriter) { grant.capture_request { flunk "Stale retained source reached HTTP" } }
    end
  end

  test "explicit absence and expired hints do not acquire a new lifetime" do
    [ nil, { value: "credit", expires_at: @now - 1.day } ].each do |raw|
      with_copy(raw: raw) do |context|
        Rails.cache.expects(:read).with(Hint.cache_key(context.source.id)).never
        retained = context.copier.snapshot_for(context.mapping).fetch("auxiliary_inputs").fetch(Hint::KEY)
        assert_equal raw.nil? ? "absent" : "present", retained.fetch("availability")
        captured = Snapshot.build(connection: context.external.provider_connection, observed_at: @now).fetch(context.external.external_id)
        assert_equal :unknown, Ingestion::BalancePolicies::Simplefin.new(snapshot: captured).call(observed_balance: "-123").classification
        if raw
          assert_equal (@now - 1.day).iso8601(9), captured.fetch("sticky_hint").fetch("expires_at")
        else
          assert_nil captured.fetch("sticky_hint")
        end
      end
    end
  end

  test "retained verification preserves the original cache observation after cache eviction" do
    with_copy(raw: { value: "debt", expires_at: @now + 1.day }) do |context|
      connection = context.external.provider_connection
      before = [ context.mapping.reload.attributes, connection.ingestion_batches.order(:id).map(&:attributes) ]
      Rails.cache.expects(:read).with(Hint.cache_key(context.source.id)).never
      page = context.copier.verify_retained_quiesced_page(family: context.family)
      assert page.complete
      assert_equal before, [ context.mapping.reload.attributes, connection.ingestion_batches.order(:id).map(&:attributes) ]
    end
  end

  test "native encrypted hints supersede retained hints even when the newer hint expires" do
    with_copy(raw: { value: "credit", expires_at: @now + 1.day }) do |context|
      context.external.update!(sensitive_details: context.external.sensitive_details.deep_merge("balance_policy_state" => {
        "simplefin" => { "value" => "debt", "expires_at" => (@now - 1.day).iso8601(9) }
      }))
      Hint.expects(:read).never
      captured = Snapshot.build(connection: context.external.provider_connection, observed_at: @now).fetch(context.external.external_id)
      assert_equal "encrypted_state", captured.fetch("sticky_hint_source")
      assert_equal "debt", captured.fetch("sticky_hint").fetch("value")
      assert_equal :unknown, Ingestion::BalancePolicies::Simplefin.new(snapshot: captured).call(observed_balance: "-123").classification
    end
  end

  test "changed source namespace or financial identity cannot inherit the old account classifier hint" do
    with_copy(raw: { value: "credit", expires_at: @now + 1.day }) do |context|
      original_id = context.external.external_id
      context.external.update_columns(external_id: "replacement-account")
      assert_raises(Provider::AccountData::StaleWriter) do
        Hint.read(connection: context.external.provider_connection, external: context.external.reload)
      end
      context.external.update_columns(external_id: original_id, identity_namespace: "replacement")
      assert_raises(Provider::AccountData::StaleWriter) do
        Hint.read(connection: context.external.provider_connection, external: context.external.reload)
      end
      context.external.update_columns(identity_namespace: "connection")
      context.account.update!(currency: "EUR")
      assert_raises(Provider::AccountData::StaleWriter) do
        Hint.read(connection: context.external.provider_connection, external: context.external.reload)
      end
    end
  end

  test "malformed cache values require disposition instead of becoming absent or fresh" do
    [ false, {}, { value: "unknown", expires_at: @now }, { value: "credit", expires_at: "2026-09-16" } ].each do |raw|
      Rails.cache.stubs(:read).with(Hint.cache_key("invalid")).returns(raw)
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { Hint.capture(legacy_id: "invalid") }
    end
    ApplicationRecord.transaction do
      assert_raises(Provider::AccountData::MigrationCopier::Conflict) { Hint.capture(legacy_id: "invalid") }
    end
  end

  private
    def with_copy(raw:)
      travel_to @now do
        with_provider_encryption do
          family = families(:dylan_family)
          account = family.accounts.create!(name: "Retained SimpleFIN card", currency: "USD", balance: 123, accountable: CreditCard.new)
          item = SimplefinItem.create!(family: family, name: "Retained SimpleFIN", access_url: "https://user:secret@bridge.example/access")
          begin
            source = item.simplefin_accounts.create!(account_id: SecureRandom.uuid, name: "Card", currency: "USD", account_type: "credit_card",
              current_balance: "-123", raw_transactions_payload: [])
            link = AccountProvider.create!(account: account, provider: source)
            Rails.cache.expects(:read).with(Hint.cache_key(source.id)).once.returns(raw)
            copier = Provider::AccountData::MigrationCopier.new(provider_key: "simplefin", legacy_item_id: item.id)
            control = nil
            10.times do
              control = copier.run_quiesced.reload
              break if control.high_water_mark["phase"] == "verified"
            end
            assert_equal "verified", control.high_water_mark["phase"]
            external = control.provider_connection.external_accounts.sole
            mapping = control.provider_migration_mappings.find_by!(external_account: external)
            yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, account: account, source: source, link: link.reload,
              copier: copier, control: control, external: external, mapping: mapping)
          ensure
            cleanup_identity_source(item, account)
            clear_enqueued_jobs
          end
        end
      end
    end
end
