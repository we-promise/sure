require "test_helper"
require "timeout"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::RetainedCopyVerifierTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier
  Fence = Provider::AccountData::LegacyWriterFence

  test "retained copy verification accepts existing identity evidence without writing any retained state" do
    with_identity_source do |context|
      identity_entry(context, external_id: "up_retained", user_modified: true, extra: { "private" => "private-financial-data" })
      Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      original = retained_state(context)
      page = nil

      queries = capture_sql_queries { page = read_page(context) }

      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_equal original, retained_state(context)
      assert page.complete
      assert_nil page.next_cursor
      assert_equal context.control.high_water_mark.fetch("copy_run_id"), page.context.fetch("copy_run_id")
      assert_equal true, page.context.fetch("requires_cutover_reverification")
      assert_equal({ "mapping_id" => context.mapping.id, "legacy_id" => context.source.id, "external_account_id" => context.external.id,
        "source_checksum" => context.mapping.source_checksum, "account_id" => context.account.id, "account_currency" => context.account.currency,
        "accountable_type" => context.account.accountable_type, "accountable_id" => context.account.accountable_id, "account_provider_id" => context.link.id,
        "account_provider_revision" => context.link.lock_version, "disposition" => "linked" }, page.rows.sole)
      refute_includes page.inspect, "private-financial-data"
      assert context.control.quiescing?
      assert context.external.provider_connection.disabled?
      assert_raises(Copier::Conflict) { context.copier.resume_legacy! }
    end
  end

  test "fresh verifier instances resume bounded pages and retain explicit unlinked dispositions" do
    with_identity_source do |context|
      2.times { |index| context.item.up_accounts.create!(account_id: "unlinked-#{index}", name: "Unlinked #{index}", currency: "USD") }
      finish_copy(context, restart: true)
      expected_ids = context.item.up_accounts.order(:id).pluck(:id)
      original = retained_state(context)
      pages, cursor = [], nil
      3.times do
        page = read_page(context, cursor: cursor, limit: 1)
        pages << page
        cursor = page.next_cursor
      end

      assert_equal expected_ids, pages.flat_map(&:rows).map { |row| row.fetch("legacy_id") }
      assert_equal [ false, false, true ], pages.map(&:complete)
      assert_equal 1, pages.map(&:context).uniq.size
      assert_equal 3, pages.first.context.fetch("account_count")
      assert_equal 2, pages.flat_map(&:rows).count { |row| row["disposition"] == "unlinked" }
      pages.flat_map(&:rows).select { |row| row["disposition"] == "unlinked" }.each do |row|
        assert_nil row.fetch("account_id")
        assert_nil row.fetch("account_provider_id")
      end
      assert pages.first.context.frozen?
      assert pages.first.rows.frozen?
      assert pages.first.rows.sole.frozen?
      assert pages.first.next_cursor.frozen?
      assert_raises(FrozenError) { pages.first.next_cursor["after_id"] = SecureRandom.uuid }
      assert_equal original, retained_state(context)
    end
  end

  test "an empty copied item verifies without inventing an external account or financial checkpoint" do
    with_empty_copy do |item, control|
      before = [ control.reload.attributes, control.provider_connection.attributes,
        control.provider_migration_mappings.order(:id).map(&:attributes), control.provider_connection.ingestion_batches.order(:id).map(&:attributes) ]
      page = nil
      assert_no_difference [ "ExternalAccount.count", "Account.count", "IngestionBatch.count", "ProviderSyncCheckpoint.count", "SourceRecord.count", "EntrySource.count" ] do
        page = Copier.new(provider_key: "up", legacy_item_id: item.id).verify_retained_quiesced_page(family: item.family)
      end

      assert page.complete
      assert_empty page.rows
      assert_nil page.next_cursor
      assert_equal 0, page.context.fetch("account_count")
      assert_equal before, [ control.reload.attributes, control.provider_connection.reload.attributes,
        control.provider_migration_mappings.order(:id).map(&:attributes), control.provider_connection.ingestion_batches.order(:id).map(&:attributes) ]
    end
  end

  test "retained verification rejects a copy missing native currency without upgrading it" do
    DebugLogEntry.expects(:capture).once
    with_empty_copy(provider_key: "trading212", currency: "EUR", api_key: "key", api_secret: "secret") do |item, control|
      connection = control.provider_connection
      connection.update_columns(settings: connection.settings.except("currency"))
      original = [ control.reload.attributes, connection.reload.attributes, control.provider_migration_mappings.order(:id).map(&:attributes) ]

      error = assert_raises(Copier::Conflict) do
        Copier.new(provider_key: "trading212", legacy_item_id: item.id).verify_retained_quiesced_page(family: item.family)
      end

      assert_equal "Copied ProviderConnection settings differs", error.message
      assert_equal original, [ control.reload.attributes, connection.reload.attributes, control.provider_migration_mappings.order(:id).map(&:attributes) ]
      assert connection.disabled?
      assert control.quiescing?
    end
  end

  test "retained verification rejects missing native token expiry without refreshing or upgrading it" do
    DebugLogEntry.expects(:capture).once
    with_empty_copy(provider_key: "snaptrade", oauth_access_token: "access", oauth_token_expires_at: Time.utc(2026, 9, 15, 12)) do |item, control|
      connection = control.provider_connection
      connection.update_columns(credentials: connection.credentials.except("oauth_token_expires_at"))
      original = [ control.reload.attributes, connection.reload.attributes, control.provider_migration_mappings.order(:id).map(&:attributes) ]

      error = assert_raises(Copier::Conflict) do
        Copier.new(provider_key: "snaptrade", legacy_item_id: item.id).verify_retained_quiesced_page(family: item.family)
      end

      assert_equal "Retained connection credentials differ", error.message
      assert_equal original, [ control.reload.attributes, connection.reload.attributes, control.provider_migration_mappings.order(:id).map(&:attributes) ]
      assert_not_requested :post, Provider::Snaptrade::TOKEN_URL
      assert connection.disabled?
      assert control.quiescing?
    end
  end

  test "a shadow comparison does not satisfy retained quiesced verification" do
    with_identity_source(quiesced: false) do |context|
      before = retained_state(context)

      assert_raises(Copier::Conflict) { read_page(context) }

      assert_equal before, retained_state(context)
      assert context.control.shadow?
    end
  end

  test "changed legacy account content is rejected without resetting its original copy progress" do
    with_identity_source do |context|
      context.source.update_columns(raw_transactions_payload: [ { "id" => "later-uncovered-source-write" } ])
      before = retained_state(context)

      assert_raises(Copier::SourceChanged) { read_page(context) }

      assert_equal before, retained_state(context)
    end
  end

  test "changed legacy credentials and copied target credentials cannot pass retained verification" do
    with_identity_source do |context|
      context.item.update_columns(access_token: "changed-source-credential")
      before = retained_state(context)
      assert_raises(Copier::SourceChanged) { read_page(context) }
      assert_equal before, retained_state(context)
    end
    with_identity_source do |context|
      context.external.provider_connection.update_columns(credentials: { "access_token" => "changed-copied-credential" })
      before = retained_state(context)
      assert_raises(Copier::Conflict) { read_page(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "changed queryable account values and private copied details are detected without repairing them" do
    [ { current_balance: BigDecimal("123.4567") }, { sensitive_details: { "unreviewed" => "private-change" } } ].each do |change|
      with_identity_source do |context|
        context.external.update_columns(change)
        before = retained_state(context)

        assert_raises(Copier::Conflict) { read_page(context) }

        assert_equal before, retained_state(context)
      end
    end
  end

  test "changed archive bytes cannot be accepted because the source and mapping counts still agree" do
    with_identity_source do |context|
      archive = context.external.provider_connection.ingestion_batches.find_by!(stream: "legacy_snapshot", external_account: context.external)
      IngestionBatch.where(id: archive.id).update_all(payload: archive.payload.merge("data" => Base64.strict_encode64("changed-archive")))
      before = retained_state(context)

      assert_raises(Copier::Conflict) { read_page(context) }

      assert_equal before, retained_state(context)
    end
  end

  test "new source and extra shared target inventory rows prevent an apparently complete retained pass" do
    with_identity_source do |context|
      context.item.up_accounts.create!(account_id: "late-source", name: "Late source", currency: "USD")
      before = retained_state(context)
      assert_raises(Copier::SourceChanged) { read_page(context) }
      assert_equal before, retained_state(context)
    end
    with_identity_source do |context|
      context.external.provider_connection.external_accounts.create!(external_id: "unmapped-target", name: "Unmapped target", currency: "USD")
      before = retained_state(context)
      assert_raises(Copier::SourceChanged) { read_page(context) }
      assert_equal before, retained_state(context)
    end
  end

  test "continuations reject changed family page size and copy run without changing either pass" do
    with_identity_source do |context|
      context.item.up_accounts.create!(account_id: "second", name: "Second", currency: "USD")
      finish_copy(context, restart: true)
      first = read_page(context, limit: 1)
      assert_not first.complete
      before = retained_state(context)
      assert_raises(Copier::Conflict) { read_page(context, cursor: first.next_cursor, limit: 2) }
      assert_raises(Copier::Conflict) { read_page(context, cursor: first.next_cursor.merge("family_id" => families(:empty).id), limit: 1) }
      assert_raises(Copier::Conflict) { read_page(context, family: families(:empty), cursor: first.next_cursor, limit: 1) }
      assert_equal before, retained_state(context)

      finish_copy(context, restart: true)
      restarted = retained_state(context)
      assert_not_equal first.context.fetch("copy_run_id"), context.control.reload.high_water_mark.fetch("copy_run_id")
      assert_raises(Copier::Conflict) { read_page(context, cursor: first.next_cursor, limit: 1) }
      assert_equal restarted, retained_state(context)
    end
  end

  test "retained verification cannot weaken native-use or unrelated checkpoint admission guards" do
    with_identity_source do |context|
      context.external.provider_connection.provider_sync_checkpoints.create!(stream: "transactions", scope_key: "connection", cursor: "native-cursor")
      before = retained_state(context)

      assert_raises(Copier::Conflict) { read_page(context) }

      assert_equal before, retained_state(context)
    end
  end

  test "Enable Banking verifies the original application consent and exact active account membership without writes" do
    with_enable_banking_copy do |context|
      connection = context.external.provider_connection
      authorization = connection.provider_authorizations.sole
      membership = authorization.provider_authorization_accounts.sole
      before = retained_state(context)
      page = nil

      queries = capture_sql_queries { page = read_page(context) }

      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert page.complete
      assert_equal context.link.id, page.rows.sole.fetch("account_provider_id")
      assert_equal "linked", page.rows.sole.fetch("disposition")
      assert_equal "private-certificate", connection.credentials.fetch("client_certificate")
      assert_equal "private-session", authorization.credentials.fetch("session_id")
      assert_equal context.external.id, membership.external_account_id
      assert membership.active?
      assert_equal before, retained_state(context)
      refute_includes page.inspect, "private-certificate"
      refute_includes page.context.to_json, "private-session"
    end
  end

  test "unmapped authorization rows cannot expand a copied consent or add consent to a grantless provider" do
    [ method(:with_enable_banking_copy), method(:with_identity_source) ].each do |fixture|
      fixture.call do |context|
        context.external.provider_connection.provider_authorizations.create!(external_id: "unreviewed-grant",
          credentials: { "session_id" => "private-unreviewed-session" })
        before = retained_state(context)

        assert_raises(Copier::Conflict) { read_page(context) }

        assert_equal before, retained_state(context)
      end
    end
  end

  test "a revoked copied consent membership is rejected rather than repaired by verification" do
    with_enable_banking_copy do |context|
      context.external.provider_authorization_accounts.sole.update!(status: "revoked")
      before = retained_state(context)

      assert_raises(Copier::Conflict) { read_page(context) }

      assert_equal before, retained_state(context)
    end
  end

  test "a competing real session holding the exclusive legacy permit prevents verification without changing retained state" do
    skip "Requires two database sessions" if ApplicationRecord.connection_pool.size < 2
    with_identity_source do |context|
      before = retained_state(context)
      ready, release = Queue.new, Queue.new
      worker = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Fence.with_exclusive(context.item) do
            ready << true
            release.pop
          end
        end
      end
      begin
        Timeout.timeout(5) { ready.pop }
        assert_raises(Fence::Busy) { Timeout.timeout(5) { read_page(context) } }
        assert_equal before, retained_state(context)
      ensure
        release << true
        begin
          Timeout.timeout(5) { worker.value }
        ensure
          worker.kill if worker.alive?
          worker.join
        end
      end

      assert read_page(context).complete
      assert_equal before, retained_state(context)
    end
  end

  private
    def read_page(context, family: context.family, cursor: nil, limit: 100)
      Copier.new(provider_key: context.control.provider_key, legacy_item_id: context.item.id)
        .verify_retained_quiesced_page(family: family, cursor: cursor, limit: limit)
    end

    def finish_copy(context, restart:)
      context.copier.run_quiesced(restart: restart)
      15.times do
        control = Copier.new(provider_key: context.control.provider_key, legacy_item_id: context.item.id, batch_size: 1).run_quiesced
        return if control.high_water_mark["phase"] == "verified"
      end
      flunk "Retained-copy fixture did not complete its bounded source copy"
    end

    def retained_state(context)
      manifest = context.copier.manifest
      connection = context.external.provider_connection.reload
      { control: context.control.reload.attributes, item: context.item.reload.attributes,
        connection: connection.attributes,
        source_accounts: manifest.account_type.constantize.where(manifest.account_foreign_key => context.item.id).order(:id).map(&:attributes),
        external_accounts: connection.external_accounts.order(:id).map(&:attributes),
        authorizations: connection.provider_authorizations.order(:id).map(&:attributes),
        memberships: ProviderAuthorizationAccount.where(provider_connection: connection).order(:id).map(&:attributes),
        mappings: context.control.provider_migration_mappings.order(:id).map(&:attributes),
        batches: connection.ingestion_batches.order(:id).map(&:attributes),
        checkpoints: connection.provider_sync_checkpoints.order(:id).map(&:attributes),
        source_records: SourceRecord.where(external_account: context.external).order(:id).map(&:attributes),
        entry_sources: EntrySource.where(bootstrap_external_account: context.external).order(:id).map(&:attributes),
        financial: identity_financial_snapshot(context), link: context.link.reload.attributes }
    end

    def with_enable_banking_copy
      with_provider_encryption do
        family = families(:dylan_family)
        item = EnableBankingItem.create!(family: family, name: "Retained consent", country_code: "FI",
          application_id: "app-id", client_certificate: "private-certificate", authorization_id: "grant-id",
          session_id: "private-session", session_expires_at: 1.day.from_now.change(usec: 0),
          aspsp_id: "bank-fi", aspsp_name: "Example Bank", last_psu_ip: "192.0.2.10")
        account = family.accounts.create!(name: "Retained consent account", currency: "EUR", balance: BigDecimal("1234.5678"),
          accountable: Depository.new, status: "active")
        begin
          source = item.enable_banking_accounts.create!(uid: "stable-account-hash", account_id: SecureRandom.uuid,
            name: "Everyday", currency: "EUR", iban: "private-iban", identification_hashes: [ "stable-account-hash" ])
          link = AccountProvider.create!(account: account, provider: source)
          copier = Copier.new(provider_key: "enable_banking", legacy_item_id: item.id, batch_size: 1)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          assert control.quiescing?
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account, link: link.reload,
            copier: copier, control: control, mapping: mapping, external: external)
        ensure
          cleanup_identity_source(item, account)
        end
      end
    end

    def with_empty_copy(provider_key: "up", **attributes)
      with_provider_encryption do
        item_class = Provider::AccountData::MigrationManifest.for(provider_key).item_type.constantize
        values = { family: families(:dylan_family), name: "Empty retained item" }
        values[:access_token] = "private-empty-token" if provider_key == "up"
        item = item_class.create!(values.merge(attributes))
        control = nil
        begin
          5.times do
            control = Copier.new(provider_key: provider_key, legacy_item_id: item.id).run_quiesced
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          yield item, control
        ensure
          connection = control&.provider_connection
          connection&.provider_sync_checkpoints&.delete_all
          ProviderMigrationAccountBinding.where(family_id: control.family_id,
            provider_migration_mapping_id: control.provider_migration_mappings.select(:id)).delete_all if control
          connection&.ingestion_batches&.delete_all
          control&.provider_migration_mappings&.delete_all
          control&.delete
          connection&.destroy!
          item.delete
        end
      end
    end
end
