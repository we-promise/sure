require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::EnableBanking::AuthorizationInventoryTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  Inventory = Provider::AccountData::EnableBanking::AuthorizationInventory

  setup do
    travel_to Time.utc(2026, 9, 16, 12)
    Provider::AccountData::EnableBanking.stubs(:native_ready?).returns(true)
    Provider::AccountData::RuntimeContext.stubs(:pending_preference).returns(false)
    DebugLogEntry.stubs(:capture)
    Account.any_instance.stubs(:sync_later)
    clear_enqueued_jobs
  end

  teardown do
    clear_enqueued_jobs
    travel_back
  end

  test "successive consent pages add isolated memberships and retain immutable original request grants on replay" do
    with_connection do |connection|
      first, second = grants(connection, 2)
      client = Client.new(first.id => [ details("a") ], second.id => [ details("b") ])
      sync = perform(connection, client)
      batches = connection.ingestion_batches.where(stream: "accounts").order(:sequence).to_a

      assert_equal [ first.id, second.id ], client.requests.select { |row| row.first == :session }.map(&:last)
      assert_equal 2, batches.size
      assert_empty Ingestion::Codec.load(batches.first.payload).evidence.dig("request_grant", "after", "memberships")
      assert_equal 1, Ingestion::Codec.load(batches.last.payload).evidence.dig("request_grant", "before", "memberships").size
      assert_equal({ "stable-a" => first.id, "stable-b" => second.id }, memberships(connection))
      assert connection.external_accounts.all? { |external| external.metadata["authorization_id"] == external.provider_authorizations.sole.id }
      originals = batches.map { |batch| [ batch.id, batch.payload, stored_payload(batch) ] }

      assert_no_difference [ "ExternalAccount.count", "ProviderAuthorizationAccount.count", "IngestionBatch.count" ] do
        perform(connection, Client.new({}), sync: sync)
      end
      assert_equal originals, batches.map { |batch| [ batch.id, batch.reload.payload, stored_payload(batch) ] }
    end
  end

  test "a newly discovered membership supports alias discovery and financial streams after explicit linking" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      perform(connection, Client.new(grant.id => [ details("a") ]))
      external = connection.external_accounts.sole
      membership = external.provider_authorization_accounts.sole
      account = link_account(external)
      rotated = details("rotated", identification_hash: "stable-a")
      client = Client.new(grant.id => [ rotated ])

      assert_difference "account.entries.transactions.count", 1 do
        perform(connection, client)
      end

      assert_equal external.id, connection.external_accounts.sole.id
      assert_equal membership.id, external.provider_authorization_accounts.sole.id
      assert_equal "api-rotated", external.reload.sensitive_details["api_account_id"]
      assert_equal [ :session, :details, :balances, :transactions ], client.requests.map(&:first)
      assert_equal "EUR", account.entries.transactions.sole.currency
      transaction_batch = connection.ingestion_batches.where(stream: "transactions").sole
      assert_equal grant.id, transaction_batch.source_binding.fetch("authorizations").sole.fetch("id")
      assert_equal membership.id, transaction_batch.source_binding.fetch("authorizations").sole.fetch("membership_id")
    end
  end

  test "an older native discovered account with captured consent metadata gains its missing membership before account reads" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      external = create_external_account(connection, external_id: "stable-a", currency: "EUR",
        metadata: { "authorization_id" => grant.id }, sensitive_details: { "api_account_id" => "api-a" })
      account = link_account(external)

      perform(connection, Client.new(grant.id => [ details("a") ]))

      assert_equal grant.id, external.provider_authorization_accounts.sole.provider_authorization_id
      assert_equal BigDecimal("25"), account.reload.balance
      assert_equal BigDecimal("2.50"), account.entries.transactions.sole.amount
    end
  end

  test "copied consent membership remains valid before native metadata has an authorization id" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      external = create_external_account(connection, external_id: "stable-a", currency: "EUR")
      membership = ProviderAuthorizationAccount.create!(provider_authorization: grant, external_account: external)

      assert_no_difference "ProviderAuthorizationAccount.count" do
        perform(connection, Client.new(grant.id => [ details("a") ]))
      end

      assert_equal membership.id, external.provider_authorization_accounts.sole.id
      assert_equal grant.id, external.reload.metadata["authorization_id"]
    end
  end

  test "another consent cannot adopt the same connection account identity" do
    with_connection do |connection|
      first, second = grants(connection, 2)
      client = Client.new(first.id => [ details("a") ], second.id => [ details("b", identification_hash: "stable-a") ])

      assert_raises(Inventory::Conflict) { perform(connection, client) }

      external = connection.external_accounts.sole
      assert_equal "stable-a", external.external_id
      assert_equal first.id, external.metadata["authorization_id"]
      assert_equal [ first.id ], external.provider_authorization_accounts.pluck(:provider_authorization_id)
      assert_equal [ "applied", "captured" ], connection.ingestion_batches.order(:sequence).pluck(:status)
      assert_empty connection.provider_sync_checkpoints
    end
  end

  test "a foreign family's consent id in a response cannot publish account metadata or membership" do
    with_connection do |connection|
      grants(connection, 1)
      with_connection do |foreign|
        foreign_grant = grants(foreign, 1).sole
        record = Ingestion::Record.account(external_id: "foreign", name: "Wrong owner", currency: "EUR",
          metadata: { authorization_id: foreign_grant.id, balance_provided: false },
          sensitive_details: { api_account_id: "foreign", identification_hashes: [ "foreign" ] })
        page = Provider::AccountData::Page.new(records: [ record ], mode: "snapshot", complete: true,
          evidence: { "authorization_id" => foreign_grant.id })
        Provider::AccountData::EnableBanking.any_instance.stubs(:list_accounts).returns(page)

        assert_no_difference [ "ExternalAccount.count", "ProviderAuthorizationAccount.count" ] do
          assert_raises(Inventory::Conflict) { perform(connection, Client.new({})) }
        end
        assert_equal "captured", connection.ingestion_batches.sole.status
        assert_empty connection.provider_sync_checkpoints
      end
    end
  end

  test "partial inventory preserves successful additions and does not revoke an unavailable consent" do
    [ false, true ].each do |failed_first|
      with_connection do |connection|
        ordered = grants(connection, 2)
        good, failed = failed_first ? ordered.reverse : ordered
        retained = create_external_account(connection, external_id: "retained", currency: "EUR",
          metadata: { "authorization_id" => failed.id })
        membership = ProviderAuthorizationAccount.create!(provider_authorization: failed, external_account: retained)
        original = membership.attributes
        client = Client.new(good.id => [ details("a") ], failed.id => :unavailable)

        assert_raises(Provider::AccountData::IncompletePage) { perform(connection, client) }

        assert_equal ordered.map(&:id), client.requests.select { |row| row.first == :session }.map(&:last)
        assert_equal({ "stable-a" => good.id, "retained" => failed.id }, memberships(connection))
        assert_equal original, membership.reload.attributes
        assert failed.reload.active?
        assert_equal 2, connection.ingestion_batches.where(status: "applied").count
        assert_empty connection.provider_sync_checkpoints
      end
    end
  end

  test "an expired consent can retain an empty incomplete page without any membership transition" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      grant.update!(expires_at: 1.hour.ago)

      assert_raises(Provider::AccountData::IncompletePage) { perform(connection, Client.new({})) }

      assert_empty connection.external_accounts
      assert_empty ProviderAuthorizationAccount.where(provider_connection: connection)
      assert_equal "applied", connection.ingestion_batches.sole.status
      assert_empty connection.provider_sync_checkpoints
    end
  end

  test "membership publication failure rolls back the full page and retries its original captured response without HTTP" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      sync = connection.syncs.create!
      callback = lambda do |membership|
        raise "test membership failure" if membership.provider_connection_id == connection.id
      end
      ProviderAuthorizationAccount.set_callback(:create, :after, callback)
      begin
        assert_raises(Provider::AccountData::Error) do
          perform(connection, Client.new(grant.id => [ details("a") ]), sync: sync)
        end
      ensure
        ProviderAuthorizationAccount.skip_callback(:create, :after, callback)
      end
      batch = connection.ingestion_batches.sole
      original = [ batch.id, batch.payload, stored_payload(batch) ]
      assert batch.captured?
      assert_empty connection.external_accounts
      assert_empty ProviderAuthorizationAccount.where(provider_connection: connection)

      travel 1.minute
      perform(connection, Client.new({}), sync: sync)

      assert batch.reload.applied?
      assert_equal original, [ batch.id, batch.payload, stored_payload(batch) ]
      assert_equal({ "stable-a" => grant.id }, memberships(connection))
    end
  end

  test "crash after the first consent page resumes the same Sync without repeating its membership or rewriting its proof" do
    with_connection do |connection|
      first, second = grants(connection, 2)
      sync = connection.syncs.create!
      assert_raises(Provider::AccountData::Error) do
        perform(connection, Client.new(first.id => [ details("a") ], second.id => :crash), sync: sync)
      end
      original = connection.ingestion_batches.sole
      bytes = stored_payload(original)
      membership = ProviderAuthorizationAccount.where(provider_connection: connection).sole
      client = Client.new(second.id => [ details("b") ])
      travel 1.minute

      assert_difference "ProviderAuthorizationAccount.count", 1 do
        perform(connection, client, sync: sync)
      end

      assert_equal [ second.id ], client.requests.select { |row| row.first == :session }.map(&:last)
      assert_equal bytes, stored_payload(original)
      assert_equal membership.attributes, membership.reload.attributes
      assert_equal 2, connection.ingestion_batches.count
      assert connection.provider_sync_checkpoints.find_by!(stream: "accounts").ingestion_batch.applied?
    end
  end

  test "a consent credential change during HTTP retains evidence but cannot become a permitted inventory transition" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      client = Client.new(grant.id => [ details("a") ])
      client.before = ->(phase, _id) { grant.update!(credentials: { "session_id" => "replacement" }) if phase == :details }

      assert_raises(Provider::AccountData::StaleWriter) { perform(connection, client) }

      assert_empty connection.external_accounts
      assert_empty ProviderAuthorizationAccount.where(provider_connection: connection)
      assert connection.ingestion_batches.sole.captured?
    end
  end

  test "discovery cannot reactivate a revoked membership" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      external = create_external_account(connection, external_id: "stable-a", currency: "EUR",
        metadata: { "authorization_id" => grant.id })
      membership = ProviderAuthorizationAccount.create!(provider_authorization: grant, external_account: external, status: "revoked")
      original = [ external.attributes, membership.attributes ]

      assert_raises(Inventory::Conflict) { perform(connection, Client.new(grant.id => [ details("a") ])) }

      assert_equal original, [ external.reload.attributes, membership.reload.attributes ]
    end
  end

  test "inventory count and byte limits refuse publication before external or membership writes" do
    [ :MAX_RECORDS, :MAX_BYTES ].each do |limit|
      with_connection do |connection|
        grant = grants(connection, 1).sole
        stub_const(Inventory, limit, 1) do
          assert_raises(Inventory::Conflict) { perform(connection, Client.new(grant.id => [ details("a"), details("b") ])) }
        end
        assert_empty connection.external_accounts
        assert_empty ProviderAuthorizationAccount.where(provider_connection: connection)
        assert connection.ingestion_batches.sole.captured?
      end
    end
  end

  test "a new stable identity cannot bypass revoked or other consent ownership through a retained alias" do
    [ :revoked, :other_consent, :copied ].each do |source|
      with_connection do |connection|
        selected, other = grants(connection, 2)
        owner = source == :revoked ? selected : other
        metadata = { "authorization_id" => owner.id }
        retained_details = { "identification_hashes" => [ "shared-alias" ] }
        if source == :copied
          metadata = { "source_details" => Provider::AccountData::MigrationValue.encode({ "identity" => { "uid" => "old-stable", "account_id" => "shared-alias" } }) }
          retained_details = {}
        end
        external = create_external_account(connection, external_id: "old-stable", currency: "EUR", metadata: metadata, sensitive_details: retained_details)
        membership = ProviderAuthorizationAccount.create!(provider_authorization: owner, external_account: external,
          status: source == :revoked ? "revoked" : "active")
        original = [ external.attributes, membership.attributes ]
        client = Client.new(selected.id => [ details("new", identification_hashes: [ "shared-alias" ]) ])

        assert_no_difference [ "ExternalAccount.count", "ProviderAuthorizationAccount.count" ] do
          assert_raises(Inventory::Conflict) { perform(connection, client) }
        end

        assert_equal original, [ external.reload.attributes, membership.reload.attributes ]
        assert connection.ingestion_batches.sole.captured?
        assert_empty connection.provider_sync_checkpoints
      end
    end
  end

  test "distinct accounts in one consent page cannot share an alias or API UID" do
    [ :alias, :api_uid ].each do |identity|
      with_connection do |connection|
        grant = grants(connection, 1).sole
        first = details("a", identification_hashes: [ "shared-alias" ])
        second = identity == :alias ? details("b", identification_hashes: [ "shared-alias" ]) : details("b", uid: first.fetch(:uid))
        client = Client.new(grant.id => [ first, second ])

        assert_no_difference [ "ExternalAccount.count", "ProviderAuthorizationAccount.count" ] do
          assert_raises(Inventory::Conflict) { perform(connection, client) }
        end

        assert connection.ingestion_batches.sole.captured?
        assert_empty connection.provider_sync_checkpoints
      end
    end
  end

  test "a grant present in the snapshot cannot impersonate the consent selected by the original cursor" do
    with_connection do |connection|
      first, second = grants(connection, 2)
      page = Provider::AccountData::Page.new(records: [], complete: false, mode: "snapshot",
        next_cursor: Base64.strict_encode64(JSON.generate(version: 1, operation: "accounts", state: { index: 1, failed: false })),
        evidence: { "authorization_id" => second.id, "session" => { "accounts" => [] }, "account_details" => [] })
      Provider::AccountData::EnableBanking.any_instance.stubs(:list_accounts).returns(page)

      assert_raises(Inventory::Conflict) { perform(connection, Client.new({})) }

      assert_empty connection.external_accounts
      assert_empty ProviderAuthorizationAccount.where(provider_connection: connection)
    end
  end

  test "a normalized account cannot invent another UID than its original captured session and detail response" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      record = Ingestion::Record.account(external_id: "invented", name: "Invented", currency: "EUR",
        metadata: { authorization_id: grant.id, balance_provided: false },
        sensitive_details: { api_account_id: "invented", identification_hashes: [ "invented" ] })
      page = Provider::AccountData::Page.new(records: [ record ], complete: true, mode: "snapshot",
        evidence: { "authorization_id" => grant.id, "session" => { "accounts" => [ "api-a" ] }, "account_details" => [ details("a") ] })
      Provider::AccountData::EnableBanking.any_instance.stubs(:list_accounts).returns(page)

      assert_raises(Inventory::Conflict) { perform(connection, Client.new({})) }

      assert_empty connection.external_accounts
      assert_empty ProviderAuthorizationAccount.where(provider_connection: connection)
    end
  end

  test "narrowed BOOK history stays incomplete through later BOOK and pending pages without advancing prior coverage" do
    with_connection do |connection|
      grant = grants(connection, 1).sole
      perform(connection, Client.new(grant.id => [ details("a") ]))
      external = connection.external_accounts.sole
      link_account(external)
      perform(connection, Client.new(grant.id => [ details("a") ]))
      checkpoint = external.provider_sync_checkpoints.find_by!(stream: "transactions")
      original_coverage = checkpoint.covered_through
      travel 1.day
      grant.update!(expires_at: 1.day.from_now)
      Provider::AccountData::RuntimeContext.stubs(:pending_preference).returns(true)
      client = Client.new(grant.id => [ details("a") ])
      client.narrow_book = true

      sync = perform(connection, client)

      pages = connection.ingestion_batches.where(sync: sync, stream: "transactions").order(:sequence).map { |batch| Ingestion::Codec.load(batch.payload) }
      assert_equal 3, pages.size
      assert pages.all? { |page| page.coverage["history_complete"] == false }
      assert pages.last.complete?
      assert_equal original_coverage, checkpoint.reload.covered_through
      assert_equal false, checkpoint.state.dig("coverage", "history_complete")
    end
  end

  private
    def with_connection
      with_provider_encryption do
        family = Family.create!(name: "Consent inventory", timezone: "UTC", currency: "EUR")
        actor = family.users.create!(email: "consent-inventory-#{SecureRandom.uuid}@example.com", password: "test-password", role: "admin")
        connection = create_provider_connection(family: family, provider_key: "enable_banking",
          credentials: { "application_id" => "test-application", "client_certificate" => "test-certificate" }, settings: { "country_code" => "DE" })
        yield connection
      ensure
        if family
          observations = SourceRecord.where(family_id: family.id)
          EntrySource.where(source_record_id: observations.select(:id)).delete_all
          HoldingSource.where(source_record_id: observations.select(:id)).delete_all
          observations.delete_all
          ProviderSyncCheckpoint.where(family_id: family.id).delete_all
          IngestionBatch.where(family_id: family.id).delete_all
          Account::SourcePolicy.where(family_id: family.id).delete_all
          AccountProvider.where(account_id: family.accounts.select(:id)).delete_all
          family.provider_connections.each(&:destroy!)
          family.accounts.destroy_all
          family.users.destroy_all
          family.destroy!
        end
        clear_enqueued_jobs
      end
    end

    def grants(connection, count)
      count.times.map do |index|
        id = format("00000000-0000-4000-8000-%012d", index + 1)
        # IDs determine consent pagination order. They are unique per fixture's
        # isolated connection except nested cross-family tests, which use UUIDs.
        id = SecureRandom.uuid if ProviderAuthorization.exists?(id: id)
        connection.provider_authorizations.create!(id: id, external_id: "consent-#{index}", expires_at: 1.day.from_now,
          credentials: { "session_id" => id }, institution_metadata: { "name" => "Bank #{index}" })
      end.sort_by(&:id)
    end

    def details(id, **changes)
      { uid: "api-#{id}", identification_hash: "stable-#{id}", name: "Checking #{id}", currency: "EUR", cash_account_type: "CACC" }.merge(changes)
    end

    def link_account(external)
      account = external.family.accounts.create!(name: "Linked bank", owner: external.family.users.sole, currency: "EUR",
        accountable: Depository.new, status: "active", balance: 10)
      link = AccountProvider.create!(account: account, external_account: external)
      Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: %w[balances transactions])
      account
    end

    def perform(connection, client, sync: connection.syncs.create!)
      Provider::EnableBanking.stub(:new, client) do
        Provider::AccountData::Syncer.new(connection.reload).perform_sync(sync)
      end
      sync
    end

    def memberships(connection)
      ProviderAuthorizationAccount.where(provider_connection: connection).includes(:external_account).to_h { |row| [ row.external_account.external_id, row.provider_authorization_id ] }
    end

    def stored_payload(batch)
      ApplicationRecord.connection.select_value(IngestionBatch.where(id: batch.id).select("payload::text").to_sql)
    end

    class Client
      attr_accessor :before, :narrow_book
      attr_reader :requests

      def initialize(sessions)
        @sessions, @requests = sessions, []
      end

      def get_ingestion_session(session_id:)
        request(:session, session_id)
        rows = @sessions.fetch(session_id)
        raise SocketError, "interrupted transport" if rows == :crash
        raise Provider::EnableBanking::EnableBankingError.new("unavailable", :unauthorized) if rows == :unavailable
        { accounts: rows.map { |row| row.fetch(:uid) }, access: { valid_until: 1.day.from_now.iso8601 } }
      end

      def get_ingestion_account_details(account_id:, psu_headers:)
        request(:details, account_id)
        @sessions.values.grep(Array).flatten.find { |row| row.fetch(:uid) == account_id } || raise(KeyError)
      end

      def get_ingestion_account_balances(account_id:, psu_headers:)
        request(:balances, account_id)
        { balances: [ { balance_type: "CLBD", balance_amount: { amount: "25.00", currency: "EUR" } } ] }
      end

      def get_ingestion_transactions_page(account_id:, date_from:, date_to:, continuation_key:, transaction_status:, psu_headers:, reference_date:)
        request(:transactions, account_id)
        narrowing = narrow_book && transaction_status == "BOOK" && continuation_key.nil?
        { items: transaction_status == "BOOK" && continuation_key.nil? ? [ { transaction_id: "booked", booking_date: Date.current.iso8601,
          transaction_amount: { amount: "2.50", currency: "EUR" }, credit_debit_indicator: "DBIT", remittance_information: "Coffee" } ] : [],
          next_cursor: narrowing ? "book-tail" : nil, date_from: narrowing ? Date.current : date_from,
          date_to: date_to, narrowed_window: narrowing, evidence: {} }
      end

      private
        def request(phase, id)
          raise "HTTP inside database transaction" unless ApplicationRecord.connection.open_transactions.zero?
          requests << [ phase, id ]
          before&.call(phase, id)
        end
    end
end
