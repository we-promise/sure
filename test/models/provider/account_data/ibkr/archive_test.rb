require "test_helper"
require_relative "../../../../support/provider_ingestion_test_helper"

class Provider::AccountData::Ibkr::ArchiveTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper

  setup do
    @observed_at = Time.utc(2026, 5, 9, 12)
    @xml = file_fixture("ibkr/flex_statement.xml").read
    @client = mock("no additional export request")
  end

  test "runtime restores the exact original sync export before inventory replay and later account slices" do
    with_archive do
      initial = adapter.list_accounts
      batch = capture(initial)
      context = Provider::AccountData::RuntimeContext.build(@connection, adapter: Provider::AccountData::Ibkr,
        sync: @sync, observed_at: @sync.created_at)
      assert_equal batch.id, context[:ibkr_export][:source_batch_id]
      Provider::IbkrFlex.expects(:new).returns(@client)
      restored = Provider::AccountData::Ibkr.build(credentials: { query_id: "q", token: "secret" }, settings: {}, context: context)
      activities = restored.fetch_activities(account: initial.records.first)
      assert_equal 4, activities.records.size
      assert_equal Digest::SHA256.hexdigest(@xml), activities.evidence["statement_sha256"]
      assert_equal @sync.id, activities.evidence["export_scope"]["sync_id"]
      assert_provider_column_encrypted(batch, :payload, "FlexQueryResponse")
    end
  end

  test "a new sync never inherits a prior completed export even if the connection and observation time match" do
    with_archive do
      original = capture(adapter.list_accounts)
      new_sync = @connection.syncs.create!(created_at: @observed_at)
      result = archive(sync: new_sync)
      assert_nil result[:export]
      assert_nil result[:source_batch_id]
      assert_not_equal @scope["sync_id"], result[:scope]["sync_id"]
      assert_raises(Provider::AccountData::InvalidResponse) do
        Provider::AccountData::Ibkr::Archive.resolve(connection: @connection, sync: new_sync, observed_at: new_sync.created_at, source_batch_id: original.id)
      end
    end
  end

  test "pending status XML is never treated as a statement artifact" do
    with_archive do
      @client.expects(:request_statement_page).returns(status: "requested", reference: "reference", evidence: { "response_xml" => "<FlexStatementResponse />" })
      page = adapter(xml: nil).list_accounts
      capture(page)
      assert_nil archive[:export]
      assert_nil archive[:source_batch_id]
    end
  end

  test "matching duplicate captures are accepted but differing XML in one sync is rejected" do
    with_archive do
      first = capture(adapter.list_accounts)
      capture(adapter.list_accounts, sequence: 1)
      assert_equal first.id, archive[:source_batch_id]
      capture(adapter(xml: @xml.sub('tradePrice="140.00"', 'tradePrice="141.00"')).list_accounts, sequence: 2)
      assert_raises(Provider::AccountData::InvalidResponse) { archive }
      assert_raises(Provider::AccountData::InvalidResponse) do
        Provider::AccountData::Ibkr::Archive.resolve(connection: @connection, sync: @sync, observed_at: @sync.created_at, source_batch_id: first.id)
      end
    end
  end

  test "matching duplicate artifacts are parsed once including named artifact resolution" do
    with_archive do
      page = adapter.list_accounts
      first = capture(page)
      second = capture(page, sequence: 1)
      statement = Provider::AccountData::Ibkr::Statement.new(@xml, observed_on: Date.iso8601(@scope["observed_on"]))
      Provider::AccountData::Ibkr::Statement.expects(:new).once.with(@xml, observed_on: Date.iso8601(@scope["observed_on"])).returns(statement)
      restored = Provider::AccountData::Ibkr::Archive.resolve(connection: @connection, sync: @sync,
        observed_at: @sync.created_at, source_batch_id: second.id)
      assert_equal second.id, restored[:batch].id
      assert_equal @xml, restored[:export].statement.xml
      assert_not_equal first.id, restored[:batch].id
    end
  end

  test "aggregate stored size and page count are checked before any payload is decoded" do
    with_archive do
      page = adapter.list_accounts
      capture(page)
      capture(page, sequence: 1)
      stored_bytes = @connection.ingestion_batches.where(sync: @sync).pick(Arel.sql("SUM(octet_length(payload))")).to_i
      Ingestion::Codec.expects(:load).never
      with_archive_limit(:MAX_STORED_BYTES, stored_bytes - 1) do
        assert_raises(Provider::AccountData::IncompletePage) { archive }
      end
      with_archive_limit(:MAX_BATCHES, 1) do
        assert_raises(Provider::AccountData::IncompletePage) { archive }
      end
    end
  end

  test "decoded budget counts all repeated artifact bytes before decoding the next page" do
    with_archive do
      page = adapter.list_accounts
      first = capture(page)
      capture(page, sequence: 1)
      bytes = JSON.generate(first.reload.payload).bytesize
      Ingestion::Codec.expects(:load).once.with(first.payload).returns(page)
      with_archive_limit(:MAX_ARCHIVE_BYTES, bytes * 2 - 1) do
        error = assert_raises(Provider::AccountData::IncompletePage) { archive }
        assert_match "decoded byte budget", error.message
      end
    end
  end

  test "tampered response bytes or frozen observation scope cannot restore an export" do
    with_archive do
      value = Provider::AccountData::Ibkr::Export.new(xml: @xml, scope: @scope).payload
      changed = value.deep_dup
      changed["response_xml"] = @xml.sub('tradePrice="140.00"', 'tradePrice="141.00"')
      assert_raises(ArgumentError) { Provider::AccountData::Ibkr::Export.load(changed, expected_scope: @scope) }
      changed = value.deep_dup
      changed["scope"]["observed_on"] = "2026-05-10"
      assert_raises(ArgumentError) { Provider::AccountData::Ibkr::Export.load(changed, expected_scope: @scope) }
      assert_raises(Provider::AccountData::InvalidResponse) do
        Provider::AccountData::Ibkr::Archive.build(connection: @connection, sync: @sync, observed_at: @observed_at + 1)
      end
    end
  end

  test "same XML copied from another connection or family cannot become this sync's export" do
    with_archive do
      other_scope = @scope.merge("family_id" => "another-family", "provider_connection_id" => "another-connection")
      page = adapter(scope: other_scope).list_accounts
      capture(page)
      assert_raises(Provider::AccountData::InvalidResponse) { archive }
    end
  end

  test "an unarchived reference and a legacy unscoped ready page fail closed" do
    with_archive do
      page = adapter.list_accounts
      reference = page.evidence["ibkr_export"].except("response_xml")
      saved = capture(Provider::AccountData::Page.new(records: page.records, complete: true, mode: "snapshot", evidence: { "ibkr_export" => reference }))
      assert_raises(Provider::AccountData::IncompletePage) { archive }
      saved.destroy!
      capture(Provider::AccountData::Ibkr.new(client: nil, timezone: @scope["timezone"], observed_at: @observed_at, staged_xml: @xml).list_accounts)
      assert_raises(Provider::AccountData::InvalidResponse) { archive }
    end
  end

  test "poll clock advances independently while the statement observation scope stays frozen" do
    with_archive do
      @client.expects(:request_statement_page).once.returns(status: "requested", reference: "reference", evidence: {})
      waiting = adapter(xml: nil).list_accounts
      @client.expects(:poll_statement_page).once.with(reference: "reference").returns(status: "ready", reference: "reference", xml: @xml, evidence: {})
      ready = adapter(xml: nil, now: @observed_at + 3).list_accounts(cursor: waiting.progress_cursor)
      assert_equal @scope, ready.evidence["ibkr_export"]["scope"]
      assert_equal @observed_at.utc.iso8601(9), ready.evidence["ibkr_export"]["scope"]["observed_at"]
      capture(ready)
      restored = Provider::AccountData::Ibkr.new(client: @client, timezone: @scope["timezone"], observed_at: @observed_at,
        now: @observed_at + 10, export_scope: @scope, staged_export: archive[:export])
      assert restored.list_accounts(cursor: waiting.progress_cursor).complete?
    end
  end

  test "unfinished poll and activity cursors cannot cross syncs even with byte-identical XML" do
    with_archive do
      @client.expects(:request_statement_page).returns(status: "requested", reference: "reference", evidence: {})
      pending = adapter(xml: nil).list_accounts
      initial = adapter
      activity = initial.fetch_activities(account: initial.list_accounts.records.first)
      next_scope = @scope.merge("sync_id" => "next-sync")
      assert_raises(Provider::AccountData::InvalidResponse) { adapter(xml: nil, scope: next_scope).list_accounts(cursor: pending.progress_cursor) }
      next_adapter = adapter(scope: next_scope)
      next_account = next_adapter.list_accounts.records.first
      assert_raises(Provider::AccountData::InvalidResponse) { next_adapter.fetch_activities(account: next_account, cursor: activity.progress_cursor) }
      assert_raises(Provider::AccountData::IncompletePage) { next_adapter.fetch_balance(account: initial.list_accounts.records.first) }
    end
  end

  test "completed activity checkpoints read the next export from its first activity" do
    with_archive do
      first = adapter
      account = first.list_accounts.records.first
      trades = first.fetch_activities(account: account)
      cash = first.fetch_activities(account: account, cursor: trades.next_cursor)
      next_adapter = adapter(scope: @scope.merge("sync_id" => "next-sync"))
      next_account = next_adapter.list_accounts.records.first
      result = next_adapter.fetch_activities(account: next_account, cursor: cash.checkpoint_cursor)
      assert_equal trades.records.map(&:attributes), result.records.map(&:attributes)
    end
  end

  test "inventory slices share one archived XML artifact and later pages retain only its reference" do
    with_archive do
      document = Nokogiri::XML(@xml)
      template = document.at_xpath("//FlexStatement").dup
      wrapper = document.at_xpath("//FlexStatements")
      wrapper.children.remove
      101.times do |index|
        copy = template.dup
        copy.xpath(".//*[@accountId] | .").each { |node| node["accountId"] = "account-#{index}" if node["accountId"] }
        wrapper.add_child(copy)
      end
      wrapper["count"] = "101"
      first = adapter(xml: document.to_xml).list_accounts
      original = capture(first)
      restored = Provider::AccountData::Ibkr.new(client: @client, timezone: @scope["timezone"], observed_at: @observed_at,
        export_scope: @scope, staged_export: archive[:export])
      last = restored.list_accounts(cursor: first.progress_cursor)
      assert_equal "account-100", last.records.sole[:external_id]
      assert_not last.evidence["ibkr_export"].key?("response_xml")
      capture(last, sequence: 1)
      assert_equal original.id, archive[:source_batch_id]
      assert_equal document.to_xml, archive[:export]["response_xml"]
    end
  end

  private
    def with_archive_limit(name, value)
      owner = Provider::AccountData::Ibkr::Archive
      previous = owner.const_get(name)
      owner.send(:remove_const, name)
      owner.const_set(name, value)
      yield
    ensure
      owner.send(:remove_const, name)
      owner.const_set(name, previous)
    end

    def with_archive
      with_provider_encryption do
        @connection = create_provider_connection(provider_key: "ibkr", writer_epoch: 1)
        @sync = @connection.syncs.create!(created_at: @observed_at)
        @scope = archive[:scope]
        yield
      end
    end

    def archive(sync: @sync)
      Provider::AccountData::Ibkr::Archive.build(connection: @connection, sync: sync, observed_at: sync.created_at)
    end

    def adapter(xml: @xml, scope: @scope, now: @observed_at)
      Provider::AccountData::Ibkr.new(client: @client, timezone: scope.fetch("timezone"), observed_at: @observed_at,
        now: now, export_scope: scope, staged_xml: xml)
    end

    def capture(page, sequence: 0)
      create_provider_batch(@connection, sync: @sync, stream: "accounts", scope_key: "connection", sequence: sequence,
        complete: page.complete?, payload: Ingestion::Codec.dump(page))
    end
end
