require "test_helper"
require_relative "../../../../support/identity_bootstrap_test_helper"

class Provider::AccountData::Plaid::CheckpointBootstrapPlanTest < ActiveSupport::TestCase
  include IdentityBootstrapTestHelper
  self.use_transactional_tests = false

  Plan = Provider::AccountData::Plaid::CheckpointBootstrapPlan
  Copier = Provider::AccountData::MigrationCopier

  setup do
    DebugLogEntry.stubs(:capture)
  end

  test "fresh planners enumerate physical modified added removed order without deduplicating or writing" do
    cache = complete_cache(
      modified: [ raw_transaction("same", amount: "1.23"), raw_transaction("same", amount: 2.34) ],
      added: [ raw_transaction("same", amount: "3.45"), raw_transaction("new") ],
      removed: [ { "transaction_id" => "same" } ])
    with_cached_source(cache: cache) do |context|
      identity_entry(context, external_id: "same", source: "plaid", user_modified: true, import_locked: true)
      before = retained_storage(context)
      Provider::Plaid.any_instance.expects(:get_transactions).never
      Provider::Plaid::IngestionClient.any_instance.expects(:get_transactions_page).never
      pages = []

      queries = capture_sql_queries { pages = all_pages(context, limit: 2) }

      assert_equal [ 2, 2, 1 ], pages.map { |page| page.document.fetch("observations").size }
      assert_equal [ false, false, true ], pages.map(&:complete)
      observations = pages.flat_map { |page| page.document.fetch("observations") }
      assert_equal %w[modified modified added added removed], observations.map { |row| row.fetch("section") }
      assert_equal [ 0, 1, 0, 1, 0 ], observations.map { |row| row.fetch("source_index") }
      assert_equal [ 0, 1, 2, 3, 4 ], observations.map { |row| row.fetch("ordinal") }
      assert_equal %w[same same same new same], observations.map { |row| row.fetch("external_id") }
      assert_equal [ BigDecimal("1.23"), BigDecimal("2.34"), BigDecimal("3.45") ],
        observations.first(3).map { |row| row.fetch("canonical").fetch("attributes").fetch(:amount) }
      assert_equal "removal_observation", observations.last.fetch("disposition")
      assert pages.all?(&:replayable?)
      pages.each do |page|
        assert_equal false, page.document.fetch("cursor_accepted")
        assert page.document.fetch("requires_cached_change_acceptance")
        assert page.document.fetch("requires_cutover_reverification")
        assert_equal "retained-private-cursor", page.document.dig("context", "next_cursor")
        assert_equal "eu", page.document.dig("context", "copy", "region")
      end
      assert_empty queries.grep(/\A(?:INSERT|UPDATE|DELETE)\b/i)
      assert_equal before, retained_storage(context)
      assert_empty context.control.provider_connection.provider_sync_checkpoints.where(stream: "transactions")
      assert_empty context.control.provider_connection.syncs
    end
  end

  test "pending exclusion retains both original and canonical observations" do
    cache = complete_cache(added: [ raw_transaction("pending", pending: true), raw_transaction("booked", pending_transaction_id: "pending") ])
    with_cached_source(cache: cache, include_pending: false) do |context|
      page = plan(context).page

      assert page.replayable?
      rows = page.document.fetch("observations")
      assert_equal %w[pending_excluded upsert_observation], rows.map { |row| row.fetch("disposition") }
      assert_equal true, rows.first.dig("raw", "pending")
      assert_equal true, rows.first.fetch("canonical").fetch("attributes").fetch(:pending)
      assert_equal "pending", rows.last.fetch("canonical").fetch("attributes").fetch(:pending_external_id)
      assert_equal({ "override" => false, "include_pending" => false }, page.document.dig("context", "pending"))
      assert_equal false, page.document.fetch("cursor_accepted")
    end
  end

  test "each source account remains separate including empty linked and populated unlinked caches" do
    with_cached_source(cache: complete_cache, extra_caches: [ complete_cache(added: [ raw_transaction("unlinked") ]) ]) do |context|
      before = retained_storage(context)

      pages = all_pages(context, limit: 1)

      assert_equal 2, pages.size
      expected_ids = context.item.plaid_accounts.order(:id).pluck(:id)
      assert_equal expected_ids, pages.map { |page| page.document.fetch("source_account").fetch("legacy_id") }
      linked = pages.find { |page| page.document.dig("source_account", "disposition") == "linked" }
      unlinked = pages.find { |page| page.document.dig("source_account", "disposition") == "unlinked" }
      assert_empty linked.document.fetch("observations")
      assert_nil unlinked.document.dig("source_account", "account_id")
      assert_equal "unlinked", unlinked.document.fetch("observations").sole.fetch("external_id")
      assert pages.all?(&:replayable?)
      assert_equal before, retained_storage(context)
      assert_empty SourceRecord.where(external_account_id: context.control.provider_connection.external_accounts.select(:id))
    end
  end

  test "default partial null and malformed caches cannot masquerade as completed empty fetches" do
    [ {}, nil, { "added" => [] }, complete_cache.merge("modified" => "invalid"), complete_cache.merge("extra" => []) ].each do |cache|
      with_cached_source(cache: cache) do |context|
        before = retained_storage(context)

        page = plan(context).page

        assert page.complete
        assert_not page.replayable?
        expected = cache == {} ? "cached_change_set_not_recorded" : "cached_change_set_incomplete_or_invalid"
        assert_equal expected, page.document.fetch("blockers").sole.fetch("code")
        assert_empty page.document.fetch("observations")
        assert_equal false, page.document.fetch("cursor_accepted")
        assert_equal before, retained_storage(context)
      end
    end
  end

  test "invalid physical rows retain their positions and do not hide later valid removals" do
    cache = complete_cache(modified: [ raw_transaction("missing").except("transaction_id"),
      raw_transaction("foreign", account_id: "another-account"), raw_transaction("invalid-amount", amount: "not-money"),
      raw_transaction("invalid-pending", pending: "false") ], removed: [ "malformed-removal", { "transaction_id" => "valid-removal" } ])
    with_cached_source(cache: cache) do |context|
      page = plan(context).page

      assert_not page.replayable?
      assert_equal [ 0, 1, 2, 3, 4, 5 ], page.document.fetch("observations").map { |row| row.fetch("ordinal") }
      assert_equal [ 0, 1, 2, 3, 4 ], page.document.fetch("blockers").map { |row| row.fetch("ordinal") }
      assert_equal %w[cached_transaction_identity_invalid cached_transaction_identity_invalid cached_transaction_normalization_failed
        cached_transaction_normalization_failed cached_transaction_identity_invalid], page.document.fetch("blockers").map { |row| row.fetch("code") }
      last = page.document.fetch("observations").last
      assert_equal "valid-removal", last.fetch("external_id")
      assert_equal "removal_observation", last.fetch("disposition")
      assert_nil last.fetch("canonical")
    end
  end

  test "removal observations cannot delete or alter a protected existing financial entry" do
    with_cached_source(cache: complete_cache(removed: [ { "transaction_id" => "removed" },
      { "transaction_id" => "assigned", "account_id" => "fixture-account" } ])) do |context|
      entry = identity_entry(context, external_id: nil, source: nil, plaid_id: "removed", user_modified: true, import_locked: true)
      before = identity_financial_snapshot(context)

      page = plan(context).page

      assert page.replayable?
      assert_equal %w[removal_observation removal_observation], page.document.fetch("observations").map { |row| row.fetch("disposition") }
      assert_equal before, identity_financial_snapshot(context)
      assert Entry.exists?(entry.id)
      assert_equal "account_cache_generation_and_unassigned_removals_not_retained", page.document.fetch("historical_coverage")
    end
  end

  test "changes to pending preference timezone or page size invalidate continuation" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      cursor = plan(context).page(limit: 1).next_cursor
      Setting.syncs_include_pending = false
      assert_raises(Plan::Conflict) { plan(context).page(cursor: cursor, limit: 1) }
      Setting.syncs_include_pending = true
      assert_raises(Plan::Conflict) { plan(context).page(cursor: cursor, limit: 2) }
      original_timezone = context.family.timezone
      begin
        context.family.update!(timezone: original_timezone == "America/Los_Angeles" ? "UTC" : "America/Los_Angeles")
        assert_raises(Plan::Conflict) { plan(context).page(cursor: cursor, limit: 1) }
      ensure
        context.family.update!(timezone: original_timezone)
      end
      assert plan(context).page(cursor: cursor, limit: 1).complete
    end
  end

  test "the explicit Plaid pending override is part of the continuation context" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      original = Rails.configuration.x.plaid.include_pending
      begin
        cursor = plan(context).page(limit: 1).next_cursor
        Rails.configuration.x.plaid.include_pending = true
        with_env_overrides("PLAID_INCLUDE_PENDING" => "true") do
          assert_raises(Plan::Conflict) { plan(context).page(cursor: cursor, limit: 1) }
          assert_equal true, plan(context).page.document.dig("context", "pending", "override")
        end
      ensure
        Rails.configuration.x.plaid.include_pending = original
      end
    end
  end

  test "unset family timezone uses a pinned deployment default across workers and rejects default changes" do
    instant = Time.utc(2026, 9, 1, 0, 30).to_i
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first", date: instant), raw_transaction("second", date: instant) ])) do |context|
      original_family_timezone = context.family.timezone
      original_default = Rails.application.config.time_zone
      begin
        context.family.update!(timezone: nil)
        Rails.application.config.time_zone = "UTC"
        first = with_env_overrides("TZ" => "UTC") { plan(context).page(limit: 1) }
        second = with_env_overrides("TZ" => "HST10") { plan(context).page(cursor: first.next_cursor, limit: 1) }

        assert_nil first.document.dig("context", "family_timezone")
        assert_equal "UTC", first.document.dig("context", "timezone")
        assert_equal first.document.fetch("context"), second.document.fetch("context")
        [ first, second ].each do |page|
          assert page.replayable?
          assert_equal Date.new(2026, 9, 1), page.document.fetch("observations").sole.fetch("canonical").fetch("attributes").fetch(:date)
        end
        Rails.application.config.time_zone = "America/Los_Angeles"
        assert_raises(Plan::Conflict) { plan(context).page(cursor: first.next_cursor, limit: 1) }
      ensure
        Rails.application.config.time_zone = original_default
        context.family.update!(timezone: original_family_timezone)
      end
    end
  end

  test "a changed archived source or copied item cursor cannot be silently rebound" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      cursor = plan(context).page(limit: 1).next_cursor
      context.source.update!(raw_transactions_payload: complete_cache)
      before = retained_storage(context)

      assert_raises(Copier::SourceChanged) { plan(context).page(cursor: cursor, limit: 1) }

      assert_equal before, retained_storage(context)
    end
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      cursor = plan(context).page(limit: 1).next_cursor
      context.item.update!(next_cursor: "rotated-copied-cursor")
      before = retained_storage(context)

      assert_raises(Copier::SourceChanged) { plan(context).page(cursor: cursor, limit: 1) }

      assert_equal before, retained_storage(context)
    end
  end

  test "default initial cursor is a plan input and never accepts or manufactures coverage" do
    with_cached_source(cache: complete_cache, next_cursor: nil) do |context|
      page = plan(context).page

      assert page.complete
      assert page.replayable?
      assert_nil page.document.dig("context", "next_cursor")
      assert_equal false, page.document.fetch("cursor_accepted")
      assert_empty context.control.provider_connection.provider_sync_checkpoints.where(stream: "transactions")
    end
    [ "now", "", "x" * 257 ].each do |cursor|
      with_cached_source(cache: complete_cache, next_cursor: cursor) do |context|
        assert_raises(Plan::Conflict) { plan(context).page }
      end
    end
  end

  test "returned evidence and cursors are deeply immutable and inspect omits private source values" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("private-first"), raw_transaction("private-second") ])) do |context|
      planner = plan(context)
      page = planner.page(limit: 1)

      assert page.document.frozen?
      assert page.next_cursor.frozen?
      assert_raises(FrozenError) { page.document.fetch("observations").first.fetch("raw")["amount"].replace("99") }
      assert_raises(FrozenError) { page.document.fetch("observations").first.fetch("canonical").fetch("attributes")[:amount] = BigDecimal("99") }
      assert_raises(FrozenError) { page.next_cursor.fetch("context")["next_cursor"].replace("changed") }
      %w[private-first private-second retained-private-cursor].each do |private_value|
        refute_includes page.inspect, private_value
        refute_includes planner.inspect, private_value
      end
    end
  end

  test "invalid limits offsets and oversized continuation documents cannot advance the reader" do
    with_cached_source(cache: complete_cache(added: [ raw_transaction("first"), raw_transaction("second") ])) do |context|
      cursor = plan(context).page(limit: 1).next_cursor
      before = retained_storage(context)
      [ 0, 501 ].each { |limit| assert_raises(ArgumentError) { plan(context).page(limit: limit) } }
      [ -1, 2, 99 ].each do |offset|
        changed = cursor.deep_dup.merge("offset" => offset)
        assert_raises(Plan::Conflict) { plan(context).page(cursor: changed, limit: 1) }
      end
      oversized = cursor.deep_dup
      oversized.fetch("context")["padding"] = "x" * (Plan::MAX_CURSOR_BYTES + 1)
      assert_raises(Plan::Conflict) { plan(context).page(cursor: oversized, limit: 1) }
      assert_equal before, retained_storage(context)
    end
  end

  test "only the copied family and a retained quiesced source can plan cached changes" do
    with_cached_source(cache: complete_cache) do |context|
      before = retained_storage(context)
      assert_raises(ArgumentError) { Plan.new(control: context.control, family: families(:empty)) }
      assert_equal before, retained_storage(context)
      begin
        context.item.update_columns(family_id: families(:empty).id)
        assert_raises(Plan::Conflict) { plan(context).page }
      ensure
        context.item.update_columns(family_id: context.family.id)
      end
    end
    with_identity_source(provider_key: "plaid", quiesced: false) do |context|
      assert_raises(Copier::Conflict) { plan(context).page }
    end
  end

  private
    def with_cached_source(cache:, next_cursor: "retained-private-cursor", include_pending: true, extra_caches: [])
      previous = Setting.unscoped.find_by(var: "syncs_include_pending")
      previous_value = previous&.value
      Setting.syncs_include_pending = include_pending
      with_env_overrides("PLAID_INCLUDE_PENDING" => nil) do
        with_identity_source(provider_key: "plaid", quiesced: false) do |context|
          context.item.update!(next_cursor: next_cursor, available_products: [ "transactions" ])
          context.source.update!(raw_transactions_payload: bind_cache(cache, context.source.plaid_id))
          extra_caches.each_with_index do |other_cache, index|
            source = context.item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Unlinked #{index}", currency: "USD",
              plaid_type: "depository", current_balance: BigDecimal("1"))
            source.update!(raw_transactions_payload: bind_cache(other_cache, source.plaid_id))
          end
          20.times do
            context.copier.run_quiesced
            break if context.control.reload.high_water_mark["phase"] == "verified"
          end
          assert context.control.quiescing?
          assert_equal "verified", context.control.high_water_mark.fetch("phase")
          context.mapping.reload
          yield context
        end
      end
    ensure
      if previous
        Setting.syncs_include_pending = previous_value
      else
        Setting.unscoped.where(var: "syncs_include_pending").destroy_all
      end
      Setting.clear_cache
    end

    def complete_cache(modified: [], added: [], removed: [])
      { "modified" => modified, "added" => added, "removed" => removed }
    end

    def raw_transaction(id, **attributes)
      { "transaction_id" => id, "account_id" => "fixture-account", "amount" => "12.34", "iso_currency_code" => "USD",
        "date" => "2026-09-01", "pending" => false, "original_description" => "Private cached description" }.merge(attributes.stringify_keys)
    end

    def bind_cache(cache, account_id)
      result = cache.deep_dup
      if result.is_a?(Hash)
        result.each_value do |rows|
          next unless rows.is_a?(Array)
          rows.each { |row| row["account_id"] = account_id if row.is_a?(Hash) && row["account_id"] == "fixture-account" }
        end
      end
      result
    end

    def plan(context)
      Plan.new(control: context.control.reload, family: context.family)
    end

    def all_pages(context, limit:)
      pages, cursor = [], nil
      30.times do
        page = plan(context).page(cursor: cursor, limit: limit)
        pages << page
        return pages if page.complete
        cursor = page.next_cursor
        assert cursor
      end
      flunk "Cached changes did not finish within their bounded pages"
    end

    def retained_storage(context)
      connection = context.control.reload.provider_connection
      { "financial" => identity_financial_snapshot(context), "item" => context.item.reload.attributes,
        "sources" => context.item.plaid_accounts.order(:id).map(&:attributes), "control" => context.control.attributes,
        "mappings" => context.control.provider_migration_mappings.order(:id).map(&:attributes),
        "connection" => connection.attributes, "external_accounts" => connection.external_accounts.order(:id).map(&:attributes),
        "batches" => connection.ingestion_batches.order(:id).map(&:attributes),
        "checkpoints" => connection.provider_sync_checkpoints.order(:id).map(&:attributes) }
    end
end
