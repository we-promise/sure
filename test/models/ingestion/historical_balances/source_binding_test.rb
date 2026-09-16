require "test_helper"
require_relative "../../../support/provider_ingestion_test_helper"

class Ingestion::HistoricalBalances::SourceBindingTest < ActiveSupport::TestCase
  include ProviderIngestionTestHelper, ActiveJob::TestHelper
  self.use_transactional_tests = false

  Binding = Ingestion::HistoricalBalances::SourceBinding
  Command = Ingestion::HistoricalBalances::Command

  setup do
    DebugLogEntry.stubs(:capture)
    Family.any_instance.stubs(:broadcast_refresh)
  end

  test "actual opening repair and equity plans capture their exact historical and balance authorities" do
    with_scenario do
      anchor = @account.entries.create!(name: "Original opening", date: Date.new(2026, 5, 1), amount: 1200, currency: "USD",
        entryable: Valuation.new(kind: "opening_anchor"))
      trade
      opening = plan.capture!(phase: "opening_anchor")
      expected = Binding.capture(command: Command.load(opening.payload))

      assert_equal expected, opening.source_binding
      assert_equal "historical-command/v1", expected.fetch("format")
      assert_equal "opening_anchor_repairs", expected.fetch("resource")
      assert_equal @policy.id, expected.fetch("source_policy_version")
      assert_equal @balance_policy.id, expected.fetch("balance_policy_version")
      assert_equal @balance_policy.id, expected.fetch("anchor_policy_version")
      assert_equal @source.id, expected.fetch("source_batch_id")
      assert_equal expected, Binding.verify!(batch: opening)
      assert_deep_frozen expected

      # Simulate the separately authorized repair/materialization phase before
      # capturing equity history. This test does not ask the index to apply it.
      anchor.update!(amount: 0)
      equity = plan.capture!(phase: "equity_history")
      assert_equal "historical_balances", equity.source_binding.fetch("resource")
      assert_equal @balance_policy.id, equity.source_binding.fetch("balance_policy_version")
      assert_nil equity.source_binding.fetch("anchor_policy_version")
      assert_equal equity.source_binding, Binding.verify!(batch: equity)
    end
  end

  test "the projection preserves a different provider balance authority without selecting it as historical owner" do
    with_scenario do
      other = create_provider_connection(family: @family, provider_key: "up")
      external = create_external_account(other)
      link = AccountProvider.create!(account: @account, external_account: external)
      selected = Account::SourcePolicy.select!(account: @account, account_provider: link, resource: "balances")
      command = plan.prepare(phase: "equity_history")
      batch = old_batch(command)

      actual = Binding.index!(batch: batch)

      assert_equal @link.id, actual.fetch("account_provider_id")
      assert_equal @external.id, actual.fetch("external_account_id")
      assert_equal @policy.id, actual.fetch("source_policy_version")
      assert_equal selected.id, actual.fetch("balance_policy_version")
      assert_nil actual.fetch("anchor_policy_version")
      assert_equal actual, Binding.verify!(batch: batch.reload)
      inventory = Account::Destruction::Sources.capture(account: @account)
      assert_equal [ @connection.id, other.id ].sort, inventory.connection_ids
      assert_includes inventory.proof.fetch("policies").map { |row| row.fetch("id") }, selected.id
    end
  end

  test "an explicitly absent balance policy remains distinct from a missing capture field" do
    with_scenario do
      @balance_policy.update!(active: false)
      command = plan.prepare(phase: "equity_history")
      original = old_batch(command)
      binding = Binding.index!(batch: original)

      assert binding.key?("balance_policy_version")
      assert_nil binding.fetch("balance_policy_version")
      assert binding.key?("anchor_policy_version")
      assert_nil binding.fetch("anchor_policy_version")

      incomplete = command.data.deep_dup
      incomplete.delete("balance_policy_version")
      malformed = old_batch(command, payload: typed_payload(incomplete))
      assert_raises(Binding::Conflict) { Binding.index!(batch: malformed) }
      assert_equal({}, malformed.reload.source_binding)
    end
  end

  test "deleted secondary policies retain the original UUID and still block source inventory acceptance" do
    with_scenario do
      batch = old_batch(plan.prepare(phase: "equity_history"))
      original_id = @balance_policy.id
      @balance_policy.destroy!

      binding = Binding.index!(batch: batch)

      assert_equal original_id, binding.fetch("balance_policy_version")
      assert_equal binding, Binding.verify!(batch: batch.reload)
      assert_raises(Account::Destruction::Sources::InvalidGraph) do
        Account::Destruction::Sources.capture(account: @account)
      end
      assert_equal original_id, batch.reload.source_binding.fetch("balance_policy_version")
    end
  end

  test "indexing old commands preserves ciphertext UUIDs timestamps and financial records" do
    with_scenario do
      trade
      command = plan.prepare(phase: "equity_history")
      batch = old_batch(command)
      before = capture_storage(batch)
      financial = [ @account.reload.attributes, @account.entries.order(:id).map(&:attributes) ]
      projected = nil
      queries = nil

      assert_no_difference [ "IngestionBatch.count", "Account.count", "Entry.count", "Trade.count", "Balance.count" ] do
        queries = capture_sql_queries do
          projected = Binding.index!(batch: batch)
        end
      end

      assert_equal Binding.capture(command: command), projected
      assert_equal before, capture_storage(batch)
      assert_equal financial, [ @account.reload.attributes, @account.entries.order(:id).map(&:attributes) ]
      assert_empty queries.grep(/\bFROM\s+"?(?:accounts|entries|trades|valuations|balances)"?\b/i)
      assert_empty queries.grep(/\A(?:INSERT|DELETE)\b/i)
      assert_provider_column_encrypted(batch, :payload, "inputs_sha256")
      assert_equal projected, Binding.index!(batch: batch.reload)
      assert_equal before, capture_storage(batch)
    end
  end

  test "backwards indexing never substitutes changed live financial inputs" do
    with_scenario do
      command = plan.prepare(phase: "equity_history")
      batch = old_batch(command)
      @account.update!(balance: 991, name: "Changed after capture")
      @link.touch
      current = @account.reload.attributes

      assert_equal Binding.capture(command: command), Binding.index!(batch: batch)

      assert_equal current, @account.reload.attributes
      assert_equal command.payload, batch.reload.payload
    end
  end

  test "legacy Plan retry indexes the original deterministic capture without preparing a replacement" do
    with_scenario do
      current = plan.capture!(phase: "equity_history")
      command = Command.load(current.payload)
      identity = { id: current.id, idempotency_key: current.idempotency_key,
        created_at: current.created_at, updated_at: current.updated_at }
      current.delete
      # Restore the same historical capture with the rollout-era empty routing
      # value. The database guard remains installed throughout this fixture.
      legacy = old_batch(command, **identity)
      original = capture_storage(legacy)
      financial = @account.reload.attributes
      retry_plan = plan
      retry_plan.expects(:prepare).never

      assert_no_difference [ "IngestionBatch.count", "Balance.count", "Entry.count" ] do
        assert_equal legacy.id, retry_plan.capture!(phase: "equity_history").id
      end

      assert_equal Binding.capture(command: command), legacy.reload.source_binding
      assert_equal original, capture_storage(legacy)
      assert_equal financial, @account.reload.attributes
    end
  end

  test "the Writer lazily indexes an original command and replay does not duplicate financial publication" do
    with_scenario do
      command = plan.prepare(phase: "equity_history")
      legacy = old_batch(command)
      ciphertext = raw_payload(legacy)
      created_at = legacy.created_at

      assert_difference -> { @account.balances.count }, 2 do
        result = Ingestion::HistoricalBalances::Writer.new(batch: legacy).apply!
        assert_equal 2, result.fetch(:applied_rows)
        refute result.fetch(:replay)
      end
      balances = @account.balances.order(:id).map(&:attributes)
      assert_equal Binding.capture(command: command), legacy.reload.source_binding
      assert_equal ciphertext, raw_payload(legacy)
      assert_equal created_at, legacy.created_at

      assert_no_difference [ "IngestionBatch.count", "Balance.count", "Entry.count" ] do
        assert Ingestion::HistoricalBalances::Writer.new(batch: legacy.reload).apply!.fetch(:replay)
      end
      assert_equal balances, @account.balances.order(:id).map(&:attributes)
      assert_equal ciphertext, raw_payload(legacy)
    end
  end

  test "completeness is separate from integrity and a false nonempty projection is never repaired" do
    with_scenario do
      command = plan.prepare(phase: "equity_history")
      false_binding = Binding.capture(command: command).deep_dup.merge("account_id" => SecureRandom.uuid)
      batch = old_batch(command, source_binding: false_binding, validate: false)

      assert_empty Binding.unindexed(family_id: @family.id)
      assert Binding.assert_complete_for!(family_id: @family.id)
      assert_raises(Binding::Conflict) { Binding.verify!(batch: batch) }
      assert_raises(Binding::Conflict) { Binding.index!(batch: batch) }
      assert_equal false_binding, batch.reload.source_binding
    end
  end

  test "foreign original tenancy or phase cannot be indexed under an unrelated batch header" do
    with_scenario do
      command = plan.prepare(phase: "equity_history")
      foreign = command.data.deep_dup
      foreign["family_id"] = families(:dylan_family).id
      foreign["inputs"]["account"]["family_id"] = foreign["family_id"]
      foreign["inputs_sha256"] = Ingestion::HistoricalBalances.fingerprint(foreign["inputs"])
      foreign_command = Command.new(foreign)
      foreign_batch = old_batch(command, payload: foreign_command.payload)
      wrong_phase = old_batch(command, stream: "opening_anchor_repairs")

      [ foreign_batch, wrong_phase ].each do |batch|
        assert_raises(Binding::Conflict) { Binding.index!(batch: batch) }
        assert_equal({}, batch.reload.source_binding)
      end
    end
  end

  test "malformed historical identities are refused without including original values in errors" do
    with_scenario do
      original = plan.prepare(phase: "equity_history").data.deep_dup
      original["balance_policy_version"] = "private-malformed-policy"
      command = Command.new(original)

      error = assert_raises(Binding::Conflict) { Binding.capture(command: command) }

      refute_includes error.message, "private-malformed-policy"
    end
  end

  test "stored payload bounds are checked before decryption" do
    with_scenario do
      batch = old_batch(plan.prepare(phase: "equity_history"))
      assert_operator raw_payload(batch).bytesize, :>, 1
      IngestionBatch.any_instance.expects(:payload).never

      with_limit(:MAX_STORED_BYTES, 1) do
        assert_raises(Binding::Conflict) { Binding.index!(batch: batch) }
      end

      assert_equal({}, batch.reload.source_binding)
    end
  end

  test "decoded bytes depth and node bounds reject whole projections" do
    with_scenario do
      batch = old_batch(plan.prepare(phase: "equity_history"))
      %i[MAX_CONTEXT_BYTES MAX_DEPTH MAX_NODES].each do |name|
        with_limit(name, 1) { assert_raises(Binding::Conflict) { Binding.index!(batch: batch) } }
        assert_equal({}, batch.reload.source_binding)
      end
    end
  end

  test "fresh capture enforces decoded bytes depth and node limits before persisting a command" do
    with_scenario do
      command = plan.prepare(phase: "equity_history")
      original = command.payload
      %i[MAX_CONTEXT_BYTES MAX_DEPTH MAX_NODES].each do |name|
        with_limit(name, 1) do
          assert_raises(Binding::Conflict) { Binding.capture(command: command) }
          assert_no_difference "IngestionBatch.count" do
            assert_raises(Binding::Conflict) { plan.capture!(phase: "equity_history") }
          end
        end
        assert_equal original, command.payload
      end

      assert_equal @account.id, Binding.capture(command: command).fetch("account_id")
    end
  end

  test "a competing batch lock returns Busy without advancing routing and remains retryable" do
    with_scenario do
      batch = old_batch(plan.prepare(phase: "equity_history"))
      outcome = Queue.new
      worker = nil
      IngestionBatch.transaction do
        IngestionBatch.where(id: batch.id).lock("FOR UPDATE").take!
        worker = Thread.new do
          ApplicationRecord.connection_pool.with_connection do
            begin
              Binding.index!(batch: batch)
              outcome << :unexpected_success
            rescue StandardError => error
              outcome << error
            end
          end
        end
        assert worker.join(5), "Historical indexing must not wait on a competing row lock"
        assert_instance_of Binding::Busy, outcome.pop
        assert_equal({}, batch.reload.source_binding)
      end

      assert_equal Binding.capture(command: Command.load(batch.payload)), Binding.index!(batch: batch)
    ensure
      worker&.kill if worker&.alive?
      worker&.join
    end
  end

  test "database guards prevent replacing original commands or completed projections while allowing application state" do
    with_scenario do
      batch = old_batch(plan.prepare(phase: "equity_history"))
      binding = Binding.index!(batch: batch)
      batch.reload
      [ { payload: { "private" => "replacement" } }, { source_binding: {} },
        { source_binding: binding.merge("account_id" => SecureRandom.uuid) },
        { source_policy_version: SecureRandom.uuid }, { created_at: batch.created_at + 1.second } ].each do |change|
        assert_raises(ActiveRecord::StatementInvalid) do
          ApplicationRecord.transaction(requires_new: true) { batch.update_columns(change) }
        end
        batch.reload
      end

      batch.update!(status: "applied", applied_at: Time.current)
      assert_equal binding, Binding.verify!(batch: batch.reload)
      assert batch.applied?
    end
  end

  test "the deployed database installs the historical command guard" do
    installed = ApplicationRecord.connection.select_value(<<~SQL)
      SELECT COUNT(*) FROM pg_trigger
      WHERE tgrelid = 'ingestion_batches'::regclass
        AND tgname = 'ingestion_historical_command_guard' AND NOT tgisinternal
    SQL
    assert_equal 1, installed.to_i, "Apply the historical command guard migration; schema.rb alone does not restore this trigger"
  end

  test "bounded backfill commits each original and continues after the saved cursor without rewriting payloads" do
    with_scenario do
      command = plan.prepare(phase: "equity_history")
      rows = Array.new(3) { SecureRandom.uuid }.sort.map { |id| old_batch(command, id: id) }
      originals = rows.to_h { |row| [ row.id, capture_storage(row) ] }
      first = Binding.backfill_page(family_id: @family.id, limit: 2)

      assert_equal 2, first.processed
      refute first.complete
      assert_equal rows[1].id, first.next_cursor
      assert_equal({}, rows.last.reload.source_binding)
      assert_raises(Binding::Incomplete) { Binding.assert_complete_for!(family_id: @family.id) }
      second = Binding.backfill_page(family_id: @family.id, after_id: first.next_cursor, limit: 2)

      assert_equal 1, second.processed
      assert second.complete
      assert_nil second.next_cursor
      assert Binding.assert_complete_for!(family_id: @family.id)
      rows.each do |row|
        assert_equal Binding.capture(command: command), Binding.verify!(batch: row.reload)
        assert_equal originals.fetch(row.id), capture_storage(row)
      end
      assert_equal 0, Binding.backfill_page(family_id: @family.id).processed
    end
  end

  test "malformed original stops a page after prior commits and cannot be concealed by advancing the cursor" do
    with_scenario do
      command = plan.prepare(phase: "equity_history")
      ids = Array.new(3) { SecureRandom.uuid }.sort
      first = old_batch(command, id: ids[0])
      bad = old_batch(command, id: ids[1], payload: { "private" => "malformed-original" })
      last = old_batch(command, id: ids[2])
      ciphertexts = [ first, bad, last ].to_h { |row| [ row.id, raw_payload(row) ] }

      error = assert_raises(Binding::Conflict) { Binding.backfill_page(family_id: @family.id, limit: 3) }
      refute_includes error.message, "malformed-original"
      assert first.reload.source_binding.present?
      assert_equal({}, bad.reload.source_binding)
      assert_equal({}, last.reload.source_binding)
      page = Binding.backfill_page(family_id: @family.id, after_id: bad.id, limit: 3)
      assert page.complete
      assert_equal 1, page.processed
      assert_raises(Binding::Incomplete) { Binding.assert_complete_for!(family_id: @family.id) }
      [ first, bad, last ].each { |row| assert_equal ciphertexts.fetch(row.id), raw_payload(row) }
      assert Binding.assert_complete_for!(family_id: families(:dylan_family).id)
    end
  end

  test "backfill refuses an outer transaction and invalid pagination before changing evidence" do
    with_scenario do
      batch = old_batch(plan.prepare(phase: "equity_history"))
      ApplicationRecord.transaction do
        assert_raises(Binding::Conflict) { Binding.backfill_page(family_id: @family.id) }
      end
      [ 0, 101, "2" ].each do |limit|
        assert_raises(ArgumentError) { Binding.backfill_page(family_id: @family.id, limit: limit) }
      end
      assert_raises(ArgumentError) { Binding.backfill_page(family_id: @family.id, after_id: "private-invalid-cursor") }
      assert_equal({}, batch.reload.source_binding)
    end
  end

  private

    def with_scenario
      with_provider_encryption do
        @family = Family.create!(name: "Historical source ownership")
        @account = @family.accounts.create!(name: "Captured investment", balance: 1200, cash_balance: 400,
          currency: "USD", accountable: Investment.new)
        @connection = create_provider_connection(family: @family, provider_key: "ibkr", writer_epoch: 1)
        @external = create_external_account(@connection, external_id: "U123", currency: "USD")
        @link = AccountProvider.create!(account: @account, external_account: @external)
        @policy = Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "historical_balances")
        @balance_policy = Account::SourcePolicy.select!(account: @account, account_provider: @link, resource: "balances")
        snapshot = Provider::AccountData::Ibkr::EquitySnapshot.new(external_id: "U123", currency: "USD", statement_sha256: "a" * 64,
          observed_on: Date.new(2026, 5, 8), imported_current_balance: BigDecimal("1200"),
          equity_rows: [ { "report_date" => "2026-05-07", "total" => "1000" }, { "report_date" => "2026-05-08", "total" => "1200" } ])
        @source = create_provider_batch(@connection, external_account: @external, stream: "equity_snapshots",
          scope_key: "account:#{@external.id}", source_policy_version: @policy.id, payload: snapshot.payload)
        yield
      ensure
        if @family&.persisted?
          IngestionBatch.where(family_id: @family.id).delete_all
          AccountProvider.where(account_id: @family.accounts.select(:id)).each(&:destroy!)
          @family.provider_connections.each(&:destroy!)
          @family.accounts.each(&:destroy!)
          @family.destroy!
          clear_enqueued_jobs
        end
      end
    end

    def plan
      Ingestion::HistoricalBalances::IbkrPlan.new(external_account: @external, source_batch: @source)
    end

    def trade
      @account.entries.create!(name: "Captured trade", date: Date.new(2026, 5, 8), amount: 100, currency: "USD",
        entryable: Trade.new(qty: 1, price: 100, currency: "USD", security: securities(:aapl)))
    end

    def old_batch(command, validate: true, **attributes)
      batch = @connection.ingestion_batches.new({ family: @family, external_account: @external, sync: @source.sync,
        origin_kind: "provider", stream: command.stream, scope_key: "account:#{@external.id}", schema_version: 1,
        writer_epoch: command[:writer_epoch], source_policy_version: command[:source_policy_version], mode: "snapshot",
        complete: command[:failed_fx_dates].empty?, idempotency_key: SecureRandom.uuid,
        payload: command.payload, source_binding: {} }.merge(attributes))
      batch.save!(validate: validate)
      batch
    end

    def typed_payload(data)
      { "format" => Ingestion::HistoricalBalances::FORMAT, "data" => Provider::AccountData::MigrationValue.encode(data) }
    end

    def raw_payload(batch)
      ApplicationRecord.connection.select_value(IngestionBatch.where(id: batch.id).select(:payload).to_sql)
    end

    def capture_storage(batch)
      batch.reload
      { "id" => batch.id, "created_at" => batch.created_at, "updated_at" => batch.updated_at,
        "payload" => raw_payload(batch), "status" => batch.status, "writer_epoch" => batch.writer_epoch }
    end

    def with_limit(name, value)
      previous = Binding.const_get(name)
      Binding.send(:remove_const, name)
      Binding.const_set(name, value)
      yield
    ensure
      Binding.send(:remove_const, name)
      Binding.const_set(name, previous)
    end

    def assert_deep_frozen(value)
      assert value.frozen?
      case value
      when Hash then value.each { |key, child| assert_deep_frozen(key); assert_deep_frozen(child) }
      when Array then value.each { |child| assert_deep_frozen(child) }
      end
    end
end
