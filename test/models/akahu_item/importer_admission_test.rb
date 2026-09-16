require "test_helper"
require_relative "../../support/provider_ingestion_test_helper"

class AkahuItem::ImporterAdmissionTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Access = AkahuItem::LegacyAccess
  Fence = Provider::AccountData::LegacyWriterFence
  BASE_URL = Provider::Akahu::DEFAULT_BASE_URL
  Context = Data.define(:family, :item, :source, :account, :link)

  setup do
    clear_enqueued_jobs
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
    Account.any_instance.stubs(:sync_later)
  end
  teardown { clear_enqueued_jobs }

  test "real transport completes every pending page outside transactions and issues one bound inventory" do
    with_source do |context|
      accounts = accounts_request(context)
      first = pending_request(items: [ transaction("pending-one") ], cursor: { next: "next-pending" })
      second = stub_request(:get, "#{BASE_URL}/transactions/pending").with(query: { cursor: "next-pending" })
        .to_return do
          assert_equal 0, ApplicationRecord.connection.open_transactions
          json_response(items: [ transaction("pending-two") ])
        end
      posted = posted_request(context, items: [ transaction("posted-one") ])
      original_account = context.account.attributes
      result = context.item.import_latest_akahu_data

      assert result[:success]
      assert_equal [ context.source.id ], result.fetch(:pending_inventories).keys
      assert result.fetch(:pending_inventories).frozen?
      assert result.fetch(:pending_inventories).fetch(context.source.id).frozen?
      assert_equal %w[posted-one pending-one pending-two], context.source.reload.raw_transactions_payload.map { |row| row.fetch("_id") }
      assert_equal original_account, context.account.reload.attributes
      assert_empty context.account.entries
      [ accounts, first, second, posted ].each { |request| assert_requested request, times: 1 }
    end
  end

  test "successful empty pending inventory is explicit while failed malformed and cyclic pages cannot authorize cleanup" do
    [ :empty, :never_cached, :failure, :declared_failure, :missing_items, :cycle, :partial ].each do |response|
      with_source do |context|
        original = transaction("old-pending").merge("_pending" => true)
        context.source.update!(raw_transactions_payload: response == :never_cached ? nil : [ original ])
        accounts_request(context)
        posted_request(context, items: [])
        case response
        when :empty, :never_cached then pending_request(items: [])
        when :failure then pending_request({ error: "private provider detail" }, status: 503)
        when :declared_failure then pending_request(success: false, items: [])
        when :missing_items then pending_request(success: true)
        when :cycle
          pending_request(items: [], cursor: { next: "cycle" })
          stub_request(:get, "#{BASE_URL}/transactions/pending").with(query: { cursor: "cycle" })
            .to_return(json_response(items: [], cursor: { next: "cycle" }))
        when :partial
          pending_request(items: [ transaction("new-pending") ], cursor: { next: "unavailable" })
          stub_request(:get, "#{BASE_URL}/transactions/pending").with(query: { cursor: "unavailable" })
            .to_return(json_response({ error: "private remote detail" }, status: 503))
        end

        result = context.item.import_latest_akahu_data

        completed = %i[empty never_cached].include?(response)
        assert_equal completed, result[:success]
        if completed
          assert_equal [ context.source.id ], result.fetch(:pending_inventories).keys
          assert_empty context.source.reload.raw_transactions_payload
        else
          assert_equal I18n.t("akahu_item.errors.pending_transactions_failed"), result[:error]
          assert_empty result.fetch(:pending_inventories)
          assert_equal [ original ], context.source.reload.raw_transactions_payload
        end
      end
    end
  end

  test "source relinking during pending or posted HTTP refuses old responses without financial publication" do
    %i[pending posted].each do |stage|
      with_source do |context|
        other = context.family.accounts.create!(name: "Replacement owner", currency: "NZD", balance: 7, accountable: Depository.new)
        accounts_request(context)
        mutation = -> { context.link.update!(account: other) }
        pending_request(items: []) { mutation.call if stage == :pending }
        posted_request(context, items: [ transaction("posted") ]) { mutation.call if stage == :posted }
        balances = context.family.accounts.order(:id).pluck(:id, :balance, :cash_balance, :currency)

        assert_raises(Fence::OwnershipChanged) { context.item.import_latest_akahu_data }

        assert_empty context.source.reload.raw_transactions_payload
        assert_equal balances, context.family.accounts.order(:id).pluck(:id, :balance, :cash_balance, :currency)
        assert_empty Entry.where(account_id: context.family.accounts.select(:id))
      end
    end
  end

  test "malformed discovery cannot publish snapshots or request transaction inventories" do
    [ { success: true }, { success: false, items: [] } ].each do |payload|
      with_source do |context|
        original = context.source.attributes
        stub_request(:get, "#{BASE_URL}/accounts").to_return(json_response(payload))

        result = context.item.import_latest_akahu_data

        refute result[:success]
        assert_empty result.fetch(:pending_inventories)
        assert_equal original, context.source.reload.attributes
        assert_nil context.item.reload.raw_payload
        assert_not_requested :get, "#{BASE_URL}/transactions/pending"
        assert_not_requested :get, "#{BASE_URL}/accounts/#{context.source.account_id}/transactions"
      end
    end
  end

  test "incomplete posted responses cannot replace pending cache or authorize cleanup" do
    %i[missing_items declared_failure cycle partial].each do |response|
      with_source do |context|
        original = transaction("old-pending").merge("_pending" => true)
        context.source.update!(raw_transactions_payload: [ original ])
        accounts_request(context)
        pending_request(items: [])
        path = "#{BASE_URL}/accounts/#{context.source.account_id}/transactions"
        payload = case response
        when :missing_items then { success: true }
        when :declared_failure then { success: false, items: [] }
        else { items: [ transaction("new-posted") ], cursor: { next: "unfinished" } }
        end
        stub_request(:get, path).with(query: {}).to_return(json_response(payload))
        if response == :cycle
          stub_request(:get, path).with(query: { cursor: "unfinished" })
            .to_return(json_response(items: [], cursor: { next: "unfinished" }))
        elsif response == :partial
          stub_request(:get, path).with(query: { cursor: "unfinished" })
            .to_return(json_response({ error: "private remote detail" }, status: 503))
        end

        result = context.item.import_latest_akahu_data

        refute result[:success]
        assert_equal 1, result[:transactions_failed]
        assert_empty result.fetch(:pending_inventories)
        assert_equal [ original ], context.source.reload.raw_transactions_payload
        assert_empty context.account.entries
      end
    end
  end

  test "either credential changing during discovery refuses item and account snapshots" do
    %i[app_token user_token].each do |field|
      with_source do |context|
        before = context.source.attributes
        accounts_request(context) { context.item.update_columns(field => "changed-credential") }

        assert_raises(Fence::OwnershipChanged) { context.item.import_latest_akahu_data }

        assert_equal before, context.source.reload.attributes
        assert_nil context.item.reload.raw_payload
        assert_not_requested :get, "#{BASE_URL}/transactions/pending"
      end
    end
  end

  test "an injected real client must match both original credential values" do
    %i[app_token user_token].each do |field|
      with_source do |context|
        credentials = { app_token: context.item.app_token, user_token: context.item.user_token }.merge(field => "foreign-credential")
        provider = Provider::Akahu.new(**credentials)
        importer = AkahuItem::Importer.new(context.item, akahu_provider: provider)

        assert_raises(Fence::OwnershipChanged) { importer.import }
        assert_not_requested :get, /api\.akahu\.io/
        assert_empty context.source.reload.raw_transactions_payload
      end
    end
  end

  test "native ownership refuses direct import and all snapshot entry points before HTTP or writes" do
    with_source do |context|
      connection = create_provider_connection(family: context.family, provider_key: "akahu",
        credentials: { "app_token" => "native-app", "user_token" => "native-user" })
      control = ProviderMigrationControl.create!(family: context.family, provider_key: "akahu", legacy_type: "AkahuItem",
        legacy_id: context.item.id, provider_connection: connection, state: "active", writer_epoch: 1)
      before = context.source.attributes
      fresh = context.item.akahu_accounts.build(account_id: "new-source")
      calls = [
        -> { context.item.import_latest_akahu_data },
        -> { context.item.upsert_akahu_snapshot!(items: []) },
        -> { context.source.upsert_akahu_snapshot!(account_row) },
        -> { context.source.upsert_akahu_transactions_snapshot!([]) },
        -> { fresh.upsert_akahu_snapshot!(account_row.merge("_id" => "new-source")) }
      ]
      calls.each { |call| assert_raises(Fence::OwnershipChanged, &call) }
      assert_equal before, context.source.reload.attributes
      assert_equal 1, context.item.akahu_accounts.count
      assert_not_requested :get, /api\.akahu\.io/
    ensure
      control&.delete
      connection&.destroy!
    end
  end

  test "transport is rejected inside an unrelated database transaction" do
    with_source do |context|
      ApplicationRecord.transaction do
        assert_raises(ArgumentError) { context.item.import_latest_akahu_data }
      end
      assert_not_requested :get, /api\.akahu\.io/
    end
  end

  test "cache callback failure rolls back the snapshot and cannot return a pending receipt" do
    with_source do |context|
      accounts_request(context)
      pending_request(items: [])
      posted_request(context, items: [ transaction("posted") ])
      source_id = context.source.id
      failure = lambda do
        raise IOError, "private callback failure" if id == source_id && saved_change_to_raw_transactions_payload?
      end
      AkahuAccount.set_callback(:update, :after, failure)
      begin
        result = context.item.import_latest_akahu_data
      ensure
        AkahuAccount.skip_callback(:update, :after, failure)
      end

      refute result[:success]
      assert_equal 1, result[:transactions_failed]
      assert_empty result.fetch(:pending_inventories)
      assert_empty context.source.reload.raw_transactions_payload
      assert_empty context.account.entries
    end
  end

  test "direct snapshots reject a different remote identity or a stale captured link" do
    with_source do |context|
      original = context.source.attributes
      expected = Access.source_context(context.source)
      assert_raises(Fence::OwnershipChanged) do
        context.source.upsert_akahu_snapshot!(account_row.merge("_id" => "foreign-source"))
      end
      assert_equal original, context.source.reload.attributes
      other = context.family.accounts.create!(name: "Changed account", currency: "NZD", balance: 0, accountable: Depository.new)
      context.link.update!(account: other)
      assert_raises(Fence::OwnershipChanged) do
        context.source.upsert_akahu_transactions_snapshot!([ transaction("posted") ], expected_context: expected)
      end
      assert_equal original, context.source.reload.attributes
    end
  end

  private
    def account_row
      { "_id" => "remote-account", "name" => "Everyday", "type" => "CHECKING", "status" => "ACTIVE",
        "connection" => { "_id" => "institution", "name" => "Test Bank" },
        "balance" => { "currency" => "NZD", "current" => 123.45, "available" => 100.0 } }
    end

    def transaction(id)
      { "_id" => id, "_account" => "remote-account", "date" => "2026-09-15", "description" => "Private purchase", "amount" => -12.5 }
    end

    def json_response(payload = nil, status: 200, **fields)
      { status: status, headers: { "Content-Type" => "application/json" }, body: (payload || fields).to_json }
    end

    def accounts_request(context, &during_request)
      stub_request(:get, "#{BASE_URL}/accounts").with(headers: { "X-Akahu-Id" => context.item.app_token,
        "Authorization" => "Bearer #{context.item.user_token}" }).to_return do
          assert_equal 0, ApplicationRecord.connection.open_transactions
          during_request&.call
          json_response(items: [ account_row ])
        end
    end

    def pending_request(payload = nil, status: 200, **fields, &during_request)
      stub_request(:get, "#{BASE_URL}/transactions/pending").with(query: {})
        .to_return do
          assert_equal 0, ApplicationRecord.connection.open_transactions
          during_request&.call
          json_response(payload || fields, status: status)
        end
    end

    def posted_request(context, items:, &during_request)
      stub_request(:get, "#{BASE_URL}/accounts/#{context.source.account_id}/transactions").to_return do
        assert_equal 0, ApplicationRecord.connection.open_transactions
        during_request&.call
        json_response(items: items)
      end
    end

    def with_source
      WebMock.reset!
      with_provider_encryption do
        family = Family.create!(name: "Akahu importer admission")
        actor = family.users.create!(email: "akahu-import-#{SecureRandom.uuid}@example.com", password: "akahu-password", role: "admin")
        item = family.akahu_items.create!(name: "Akahu import", app_token: "private-app", user_token: "private-user")
        source = item.akahu_accounts.create!(account_id: "remote-account", name: "Original source", currency: "NZD", raw_transactions_payload: [])
        account = family.accounts.create!(owner: actor, name: "Financial account", balance: 100, currency: "NZD", accountable: Depository.new)
        link = AccountProvider.create!(account: account, provider: source)
        yield Context.new(family: family, item: item, source: source, account: account, link: link)
      ensure
        if family
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          item&.akahu_accounts&.delete_all
          item&.delete
          family.accounts.each(&:destroy!)
          family.users.each(&:destroy!)
          family.destroy!
        end
        clear_enqueued_jobs
      end
    end
end
