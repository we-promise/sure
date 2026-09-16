require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Coinbase::LegacyTradeIdentityTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Resolver = Provider::AccountData::Coinbase::LegacyTradeIdentity
  Copier = Provider::AccountData::MigrationCopier

  setup do
    DebugLogEntry.stubs(:capture)
    Provider::AccountData::Coinbase.stubs(:native_ready?).returns(true)
    Provider::Coinbase.expects(:new).never
  end

  test "native buy and sell publication retain original financial UUIDs and immutable input identities" do
    %w[buy sell].each do |type|
      with_source(type: type) do |context, entry, security|
        publish_identities(context)
        enter_native(context)
        before = [ entry.reload.attributes, entry.trade.attributes ]
        page = native_page(context, type: type)

        batch = apply_page(context, page, security)

        assert_equal before, [ entry.reload.attributes, entry.trade.attributes ]
        assert_equal 1, context.account.entries.count
        observation = SourceRecord.find_by!(external_account: context.external)
        assert_equal "coinbase_#{type}_old-order", observation.external_id
        assert_equal observation.external_id, observation.input_external_id
        assert_equal entry.id, observation.entry_source.entry_identity
        assert_equal batch.id, observation.ingestion_batch_id
        assert_equal "coinbase_txn_native-transaction", Ingestion::Codec.load(batch.payload).records.sole[:external_id]
        assert_equal "old-order", Ingestion::Codec.load(batch.payload).records.sole[:metadata][:legacy_buy_sell_id]

        second = apply_page(context, page, security)
        assert_equal before, [ entry.reload.attributes, entry.trade.attributes ]
        assert_equal second.id, observation.reload.ingestion_batch_id
        assert_equal 1, SourceRecord.where(external_account: context.external).count
        assert_equal 1, EntrySource.where(bootstrap_external_account: context.external).count
      end
    end
  end

  test "archived native transaction relation works when the fresh response omits endpoint details" do
    with_source(archive: { "transactions" => [ native_transaction ] }) do |context, entry, security|
      publish_identities(context)
      enter_native(context)
      page = native_page(context, details: false)

      apply_page(context, page, security)

      assert_equal entry.id, context.account.entries.sole.id
      assert_equal "coinbase_buy_old-order", entry.reload.external_id
    end
  end

  test "later user economic edits and protections survive alias publication" do
    with_source do |context, entry, security|
      publish_identities(context)
      enter_native(context)
      entry.update!(amount: -987, name: "My trade", notes: "My notes", user_modified: true, import_locked: true)
      entry.trade.update!(qty: 4, price: 123, investment_activity_label: "Transfer")
      before = [ entry.reload.attributes, entry.trade.attributes ]

      apply_page(context, native_page(context), security)

      assert_equal before, [ entry.reload.attributes, entry.trade.attributes ]
    end
  end

  test "unsigned old financial identity is never claimed from matching endpoint metadata alone" do
    with_source do |context, entry, security|
      enter_native(context)
      before = entry.attributes

      assert_raises(Resolver::Conflict) { apply_page(context, native_page(context), security) }

      assert_equal before, entry.reload.attributes
      assert_empty SourceRecord.where(external_account: context.external)
    end
  end

  test "old signed identity without retained provider equivalence refuses" do
    with_source(archive: {}) do |context, entry, security|
      publish_identities(context)
      enter_native(context)

      assert_raises(Resolver::Conflict) { apply_page(context, native_page(context), security) }
      assert_equal entry.id, context.account.entries.sole.id
    end
  end

  test "missing current detail and missing archived relation cannot invent another transaction" do
    with_source do |context, entry, security|
      publish_identities(context)
      enter_native(context)

      assert_raises(Resolver::Conflict) { apply_page(context, native_page(context, details: false), security) }
      assert_equal entry.id, context.account.entries.sole.id
    end
  end

  test "an explicitly different new endpoint identity remains a normal native trade" do
    with_source do |context, entry, security|
      publish_identities(context)
      enter_native(context)

      apply_page(context, native_page(context, legacy_id: "new-order"), security)

      assert_equal [ "coinbase_buy_old-order", "coinbase_txn_native-transaction" ], context.account.entries.order(:external_id).pluck(:external_id)
      assert_equal entry.id, context.account.entries.find_by!(external_id: "coinbase_buy_old-order").id
      observation = SourceRecord.find_by!(external_account: context.external, external_id: "coinbase_txn_native-transaction")
      assert_equal observation.external_id, observation.input_external_id
    end
  end

  test "competing native identity or changed old source refuses without merging financial rows" do
    [ :competing, :source_changed ].each do |change|
      with_source do |context, entry, security|
        publish_identities(context)
        enter_native(context)
        if change == :competing
          context.account.entries.create!(name: "Already imported", source: "coinbase", external_id: "coinbase_txn_native-transaction",
            date: Date.current, amount: -5, currency: "USD", entryable: Trade.new(security: security, qty: 1, price: 5, currency: "USD"))
        else
          entry.update!(source: "manual")
        end
        before = identity_financial_snapshot(context)

        assert_raises(Resolver::Conflict) { apply_page(context, native_page(context), security) }

        assert_equal before, identity_financial_snapshot(context)
      end
    end
  end

  test "retired deleted or wrong-type original financial mappings cannot be recreated" do
    [ :withdrawn, :deleted, :retyped ].each do |change|
      with_source do |context, entry, security|
        publish_identities(context)
        enter_native(context)
        case change
        when :withdrawn then SourceRecord.find_by!(external_account: context.external).update!(withdrawn: true)
        when :deleted then entry.destroy!
        when :retyped
          original_trade = entry.trade
          entry.update!(entryable: Transaction.new)
          Trade.where(id: original_trade.id).delete_all
        end
        before = identity_financial_snapshot(context)

        assert_raises(Resolver::Conflict) { apply_page(context, native_page(context), security) }

        assert_equal before, identity_financial_snapshot(context)
      end
    end
  end

  test "two native transactions cannot share one legacy financial identity within or across pages" do
    with_source do |context, entry, security|
      publish_identities(context)
      enter_native(context)
      first = native_page(context)
      second = native_page(context, id: "another-native-transaction")
      combined = Provider::AccountData::Page.new(records: first.records + second.records, complete: true, mode: "delta")

      assert_raises(Resolver::Conflict) { apply_page(context, combined, security) }
      original_batch = apply_page(context, first, security)
      assert_raises(Resolver::Conflict) { apply_page(context, second, security) }

      assert_equal entry.id, context.account.entries.sole.id
      assert_equal original_batch.id, SourceRecord.find_by!(external_account: context.external).ingestion_batch_id
    end
  end

  test "captured native page cannot be replaced by a caller-created alias record" do
    with_source do |context, entry, security|
      publish_identities(context)
      enter_native(context)
      captured = native_page(context, id: "captured-id")
      current = native_page(context, id: "other-id")
      batch = capture_page(context, captured)

      assert_raises(Resolver::Conflict) { publish_page(context, batch, current, security) }
      assert_equal entry.id, context.account.entries.sole.id
    end
  end

  test "captured source policy and copied link revision remain publication requirements" do
    [ :policy, :link ].each do |changed|
      with_source do |context, entry, security|
        publish_identities(context)
        enter_native(context)
        page = native_page(context)
        batch = capture_page(context, page)
        if changed == :policy
          Account::SourcePolicy.active.find_by!(account: context.account, resource: "activities").update!(active: false)
          Account::SourcePolicy.select!(account: context.account, account_provider: context.link, resource: "activities")
        else
          context.link.update!(lock_version: context.link.lock_version + 1)
        end

        assert_raises(Provider::AccountData::StaleWriter) { publish_page(context, batch, page, security) }
        assert_equal entry.id, context.account.entries.sole.id
      end
    end
  end

  test "foreign financial account cannot borrow a retained Coinbase alias" do
    with_source do |context, _entry, _security|
      publish_identities(context)
      enter_native(context)
      page = native_page(context)
      batch = capture_page(context, page)
      foreign = families(:empty).accounts.create!(name: "Foreign wallet", currency: "USD", balance: 0, status: "active", accountable: Crypto.new)
      begin
        ApplicationRecord.transaction do
          assert_raises(Resolver::Conflict) do
            Resolver.new(external_account: context.external, account: foreign, batch: batch).resolve(page.records.sole)
          end
        end
      ensure
        foreign.destroy!
      end
    end
  end

  test "duplicate retained endpoint relations and bounded history refuse" do
    archive = { "transactions" => [ native_transaction, native_transaction(id: "another-id") ] }
    with_source(archive: archive) do |context, _entry, security|
      publish_identities(context)
      enter_native(context)
      assert_raises(Resolver::Conflict) { apply_page(context, native_page(context), security) }
    end
    with_source do |context, _entry, security|
      publish_identities(context)
      enter_native(context)
      with_limit(:MAX_ROWS, 1) { assert_raises(Resolver::Conflict) { apply_page(context, native_page(context), security) } }
      with_limit(:MAX_BYTES, 1) { assert_raises(Resolver::Conflict) { apply_page(context, native_page(context), security) } }
    end
  end

  test "malformed live endpoint IDs are refused by normalization" do
    with_source do |context, _entry, _security|
      [ {}, [], true, "", "x" * 513 ].each do |value|
        assert_raises(Provider::AccountData::InvalidResponse) { native_page(context, legacy_id: value) }
      end
    end
  end

  private
    def with_source(type: "buy", archive: nil)
      with_provider_encryption do
        family = families(:dylan_family)
        timestamps = family.reload.attributes.slice("latest_sync_activity_at", "latest_sync_completed_at", "updated_at")
        item = CoinbaseItem.create!(family: family, name: "Coinbase identity", api_key: "test-key", api_secret: "test-secret")
        account = family.accounts.create!(name: "Coinbase wallet", currency: "USD", balance: 100, accountable: Crypto.new, status: "active")
        security = Security.create!(ticker: "CB#{SecureRandom.hex(4).upcase}", name: "Retained asset", exchange_operating_mic: "XCBS")
        begin
          source = item.coinbase_accounts.create!(name: "Bitcoin", currency: "BTC", account_id: SecureRandom.uuid,
            current_balance: BigDecimal("0.5"), raw_payload: {}, raw_transactions_payload: archive || { "#{type}s" => [ legacy_transaction ] })
          link = AccountProvider.create!(account: account, provider: source)
          copier = Copier.new(provider_key: "coinbase", legacy_item_id: item.id, batch_size: 1)
          control = nil
          15.times do
            control = copier.run_quiesced.reload
            break if control.high_water_mark["phase"] == "verified"
          end
          assert_equal "verified", control.high_water_mark["phase"]
          external = control.provider_connection.external_accounts.sole
          mapping = control.provider_migration_mappings.find_by!(role: "external_account", external_account: external)
          Account::SourcePolicy.select!(account: account, account_provider: link.reload, resource: "activities")
          context = IdentityBootstrapTestHelper::Context.new(family: family, item: item, source: source, account: account,
            link: link, copier: copier, control: control, external: external, mapping: mapping)
          entry = account.entries.create!(source: "coinbase", external_id: "coinbase_#{type}_old-order", name: "Original trade",
            date: Date.new(2020, 1, 2), amount: type == "buy" ? -100 : 100, currency: "USD",
            entryable: Trade.new(security: security, qty: type == "buy" ? BigDecimal("0.5") : BigDecimal("-0.5"),
              price: 200, currency: "USD", investment_activity_label: type.capitalize))
          yield context, entry, security
        ensure
          connection = ProviderMigrationControl.find_by(legacy_type: "CoinbaseItem", legacy_id: item.id)&.provider_connection
          cleanup_identity_source(item, account)
          Sync.where(syncable_type: "ProviderConnection", syncable_id: connection.id).delete_all if connection
          security.destroy! if security.persisted?
          Family.where(id: family.id).update_all(timestamps)
        end
      end
    end

    def legacy_transaction
      { "id" => "old-order", "status" => "completed", "created_at" => "2020-01-02T12:00:00Z",
        "amount" => { "amount" => "0.5", "currency" => "BTC" }, "unit_price" => { "amount" => "200", "currency" => "USD" },
        "total" => { "amount" => "100", "currency" => "USD" } }
    end

    def native_transaction(id: "native-transaction", type: "buy", legacy_id: "old-order", details: true)
      { "id" => id, "type" => type, "status" => "completed", "created_at" => "2020-01-02T12:00:00Z",
        "amount" => { "amount" => "0.5", "currency" => "BTC" }, "native_amount" => { "amount" => "100", "currency" => "USD" },
        type => details ? { "id" => legacy_id } : {} }
    end

    def native_page(context, **options)
      adapter = Provider::AccountData::Coinbase.new(client: nil, timezone: context.family.timezone, observed_at: Time.current)
      raw = native_transaction(**options)
      record = adapter.normalize_transaction(raw, account: { external_id: context.external.external_id, currency: "USD" })
      Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "delta", evidence: { response: [ raw ] })
    end

    def publish_identities(context)
      publisher = Ingestion::IdentityBootstrap.new(mapping: context.mapping, family: context.family)
      result = nil
      10.times do
        result = publisher.run
        break if result.verified?
      end
      assert result.verified?
    end

    def enter_native(context)
      context.control.update!(state: "active", writer_epoch: 1)
      context.external.provider_connection.update!(status: "good", writer_epoch: 1)
    end

    def capture_page(context, page)
      policy = Account::SourcePolicy.active.find_by!(account: context.account, resource: "activities")
      create_provider_batch(context.external.provider_connection, external_account: context.external, stream: "activities",
        scope_key: "account:#{context.external.id}", source_policy_version: policy.id, mode: page.mode, complete: page.complete?,
        payload: Ingestion::Codec.dump(page))
    end

    def apply_page(context, page, security)
      batch = capture_page(context, page)
      publish_page(context, batch, page, security)
      batch.reload
    end

    def publish_page(context, batch, page, security)
      ApplicationRecord.transaction(requires_new: true) do
        Ingestion::LedgerWriter.new(external_account: context.external, batch: batch,
          securities: page.records.to_h { |record| [ [ record.kind, record[:external_id] ], security ] }).apply(page)
        batch.update!(status: "applied", applied_at: Time.current)
      end
    end

    def with_limit(name, value)
      previous = Resolver.const_get(name)
      Resolver.send(:remove_const, name)
      Resolver.const_set(name, value)
      yield
    ensure
      Resolver.send(:remove_const, name)
      Resolver.const_set(name, previous)
    end
end
