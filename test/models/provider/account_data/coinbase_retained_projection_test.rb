require "test_helper"
require_relative "../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::CoinbaseRetainedProjectionTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Copier = Provider::AccountData::MigrationCopier

  test "retained fallback values survive later financial edits without rewriting source target or archive" do
    with_coinbase_copy do |context|
      archive = context.copier.snapshot_for(context.mapping)
      derived = archive.fetch("derived_projection")
      assert_equal "coinbase-queryable-target/v1", derived.fetch("format")
      assert_equal BigDecimal("100.1234"), derived.fetch("attributes").fetch("current_balance")
      assert_equal BigDecimal("17.5678"), derived.fetch("attributes").fetch("cash_balance")
      assert_equal BigDecimal("0.5"), archive.fetch("attributes").fetch("current_balance")
      assert_equal context.link.reload.lock_version, derived.fetch("link").fetch("lock_version")
      assert_not derived.fetch("financial_context").key?("balance")
      assert_not derived.fetch("financial_context").key?("cash_balance")
      context.account.update!(balance: BigDecimal("200.3456"), cash_balance: BigDecimal("19.8765"), name: "My renamed wallet")
      before = retained_snapshot(context)
      page = nil

      queries = capture_sql_queries { page = retained_page(context) }

      assert page.complete
      assert_equal context.account.id, page.rows.sole.fetch("account_id")
      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_equal before, retained_snapshot(context)
      assert_equal archive, context.copier.snapshot_for(context.mapping)
    end
  end

  test "native monetary amount also retains its copy-time linked cash fallback" do
    with_coinbase_copy(native_balance: { "amount" => "321.123456789012345678", "currency" => "USD" }) do |context|
      assert_equal BigDecimal("321.123456789012345678"), context.external.current_balance
      assert_equal BigDecimal("17.5678"), context.external.cash_balance
      context.account.update!(balance: BigDecimal("9"), cash_balance: BigDecimal("88"))
      original = retained_snapshot(context)

      assert retained_page(context).complete

      assert_equal original, retained_snapshot(context)
      assert_equal BigDecimal("17.5678"), context.external.reload.cash_balance
      assert_equal "legacy_native_balance", context.external.metadata.dig("valuation", "origin")
    end
  end

  test "later financial identity publication does not require rewriting the Coinbase valuation baseline" do
    with_coinbase_copy do |context|
      trade = Trade.new(security: securities(:aapl), qty: BigDecimal("1"), price: BigDecimal("10"), currency: "USD")
      context.account.entries.create!(entryable: trade, source: "coinbase", external_id: "coinbase_txn_retained",
        name: "Existing trade", date: Date.current, amount: BigDecimal("10"), currency: "USD")
      Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "activities")
      Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family).run
      context.account.update!(balance: BigDecimal("44"), cash_balance: BigDecimal("33"))
      original = retained_snapshot(context)

      assert retained_page(context).complete

      assert_equal original, retained_snapshot(context)
      assert_raises(Copier::Conflict) { context.copier.run_quiesced(restart: true) }
    end
  end

  test "copied monetary tampering cannot use current financial values as a replacement baseline" do
    [ :current_balance, :cash_balance ].each do |column|
      with_coinbase_copy do |context|
        context.account.update!(balance: BigDecimal("999"), cash_balance: BigDecimal("999"))
        context.external.update_columns(column => BigDecimal("999"))
        original = retained_snapshot(context)

        assert_raises(Copier::Conflict) { retained_page(context) }

        assert_equal original, retained_snapshot(context)
      end
    end
  end

  test "original source changes and account context changes still require explicit reconciliation" do
    with_coinbase_copy do |context|
      context.source.update_columns(current_balance: BigDecimal("0.75"))
      original = retained_snapshot(context)

      assert_raises(Copier::SourceChanged) { retained_page(context) }

      assert_equal original, retained_snapshot(context)
    end
    with_coinbase_copy do |context|
      context.account.update!(currency: "EUR")
      error = assert_raises(Copier::Conflict) { retained_page(context) }
      assert_match(/copy-time account context changed/, error.message)
    end
    with_coinbase_copy do |context|
      context.link.touch
      error = assert_raises(Copier::Conflict) { retained_page(context) }
      assert_match(/copy-time account context changed/, error.message)
    end
  end

  test "archives without a copy-time baseline require a specific disposition instead of current target trust" do
    with_coinbase_copy do |context|
      # Build the exact pre-baseline archive through its original source-only
      # writer, without editing or weakening any checksum verification method.
      control = context.control
      Provider::AccountData::LegacyWriterFence.with_exclusive(context.item) do
        control.with_lock do
          projection = context.copier.manifest.extract_account(context.source.reload)
          context.copier.send(:save_mapping!, context.mapping, context.external, projection)
          context.copier.send(:capture_snapshot!, context.mapping, projection)
          context.mapping.update!(verified_at: Time.current)
        end
      end
      original = retained_snapshot(context)

      error = assert_raises(Copier::Conflict) { retained_page(context) }

      assert_match(/require reverse indexing/, error.message)
      assert_raises(Copier::Conflict) do
        Provider::AccountData::RetainedAccountIndex.capture!(mapping: context.mapping)
      end
      assert_equal original, retained_snapshot(context)
    end
  end

  test "a new explicit copy preserves the old archive and addresses its changed fallback under a new checksum" do
    with_coinbase_copy do |context|
      old_archive = context.copier.snapshot_for(context.mapping)
      old_checksum = context.mapping.source_checksum
      old_batches = context.external.provider_connection.ingestion_batches.where(external_account: context.external).order(:id).to_h { |batch| [ batch.id, batch.attributes ] }
      context.account.update!(balance: BigDecimal("222"), cash_balance: BigDecimal("18"))

      finish_quiesced(context.copier, restart: true)

      context.mapping.reload
      assert_not_equal old_checksum, context.mapping.source_checksum
      fresh = context.copier.snapshot_for(context.mapping)
      assert_equal old_archive.fetch("attributes"), fresh.fetch("attributes")
      assert_equal BigDecimal("222"), fresh.fetch("derived_projection").fetch("attributes").fetch("current_balance")
      assert_equal BigDecimal("100.1234"), old_archive.fetch("derived_projection").fetch("attributes").fetch("current_balance")
      old_batches.each { |id, attributes| assert_equal attributes, IngestionBatch.find(id).attributes }
      assert retained_page(context).complete
    end
  end

  private
    def with_coinbase_copy(native_balance: nil)
      with_provider_encryption do
        family = families(:dylan_family)
        item = CoinbaseItem.create!(family: family, name: "Retained wallet", api_key: "test-key", api_secret: "test-secret")
        account = family.accounts.create!(name: "Financial wallet", currency: "USD", balance: BigDecimal("100.1234"),
          cash_balance: BigDecimal("17.5678"), accountable: Crypto.new, status: "active")
        begin
          source = item.coinbase_accounts.create!(name: "Bitcoin", currency: "BTC", account_id: "retained-wallet",
            current_balance: BigDecimal("0.5"), raw_payload: native_balance ? { "native_balance" => native_balance } : {})
          link = AccountProvider.create!(account: account, provider: source)
          copier = Copier.new(provider_key: "coinbase", legacy_item_id: item.id, batch_size: 1)
          control = finish_quiesced(copier)
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          yield IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link.reload, copier: copier, control: control, external: external, mapping: mapping)
        ensure
          cleanup_identity_source(item, account)
        end
      end
    end

    def finish_quiesced(copier, restart: false)
      10.times do |attempt|
        control = copier.run_quiesced(restart: restart && attempt.zero?).reload
        return control if control.high_water_mark["phase"] == "verified"
      end
      flunk "Coinbase copy did not finish within bounded calls"
    end

    def retained_page(context)
      Copier.new(provider_key: "coinbase", legacy_item_id: context.item.id).verify_retained_quiesced_page(family: context.family)
    end

    def retained_snapshot(context)
      connection = context.external.provider_connection
      [ context.account.reload.attributes, context.source.reload.attributes, context.link.reload.attributes,
        context.external.reload.attributes, context.control.reload.attributes, context.mapping.reload.attributes,
        connection.ingestion_batches.order(:id).map(&:attributes), connection.provider_sync_checkpoints.order(:id).map(&:attributes) ]
    end
end
