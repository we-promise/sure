require "test_helper"

class TransactionTimestampsTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 9, 22, 12)
    @account = accounts(:depository)
    @account.family.update!(timezone: "Europe/Paris")
  end

  test "CSV preserves distinct same-day instants and reimports in any row order" do
    values = [ "2026-09-13T10:52:33Z", "2026-09-13T10:45:24Z" ]
    first = import_csv(values)
    original = first.entries.pluck(:transacted_at, :id).to_h
    assert_equal 2, original.size

    assert_no_difference "Entry.count" do
      import_csv(values.reverse)
    end
    assert_equal original, Entry.where(id: original.values).pluck(:transacted_at, :id).to_h
    assert_equal values, Entry.where(id: original.values).reverse_chronological.map { |entry| entry.transacted_at.utc.iso8601 }
  end

  test "CSV minute-only offsets work in both date and separate timestamp columns" do
    dated = import_csv([ "2026-09-18T01:30+02:00" ]).entries.first
    assert_equal Date.new(2026, 9, 18), dated.date
    assert_equal Time.utc(2026, 9, 17, 23, 30), dated.transacted_at

    separate = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    separate.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-19,0,Synthetic merchant,2026-09-19T10:45Z\n"
    separate.save!
    separate.generate_rows_from_csv
    separate.publish

    assert_equal "complete", separate.status, separate.error
    assert_equal Time.utc(2026, 9, 19, 10, 45), separate.entries.first.transacted_at
  end

  test "date policy is saved and changing it on reimport does not move existing entries" do
    value = "2026-09-17T23:30:00Z"
    entry = import_csv([ value ], date_basis: "source").entries.first
    assert_equal Date.new(2026, 9, 17), entry.date

    assert_no_difference "Entry.count" do
      import_csv([ value ], date_basis: "local")
    end
    assert_equal Date.new(2026, 9, 17), entry.reload.date

    local = import_csv([ "2026-09-18T23:30:00Z" ], date_basis: "local")
    assert_equal Date.new(2026, 9, 19), local.entries.first.date
    @account.family.update!(timezone: "America/New_York")
    assert_equal "2026-09-19", local.reload.rows.first.date_iso
  end

  test "date validation uses the selected timezone at midnight in requests and jobs" do
    travel_back
    travel_to Time.utc(2026, 9, 17, 23, 30)
    local = import_csv([ "2026-09-17T23:15:00Z" ], date_basis: "local")
    assert local.rows.first.valid?, local.rows.first.errors.full_messages.join(", ")

    source = import_csv([ "2026-09-18T01:16:00+02:00" ], date_basis: "source")
    Time.use_zone("America/New_York") do
      assert source.rows.first.valid?, source.rows.first.errors.full_messages.join(", ")
      assert local.rows.first.valid?, local.rows.first.errors.full_messages.join(", ")
    end
  end

  test "a separate timestamp does not change the source offset used for date validation" do
    travel_back
    travel_to Time.utc(2026, 9, 17, 23, 30)
    @account.family.update!(timezone: "America/New_York")
    import = build_import(date_format: "iso8601", date_basis: "source", timestamp_col_label: "Occurred")
    import.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-18T01:16:00+02:00,0,Synthetic merchant,2026-09-17T23:16:00Z\n"
    import.save!
    import.generate_rows_from_csv

    assert import.rows.first.valid?, import.rows.first.errors.full_messages.join(", ")
  end

  test "manual correction and clearing survive timestamped and date-only CSV reimports" do
    value = "2026-09-17T14:48:50Z"
    entry = import_csv([ value ]).entries.first
    entry.update!(transacted_at_local: "2026-09-17T18:00:12")
    entry.lock_saved_attributes!
    entry.mark_user_modified!
    corrected = entry.transacted_at

    assert_no_difference "Entry.count" do
      import_csv([ value ])
      import_csv([ "2026-09-17" ], date_format: "%Y-%m-%d")
    end
    assert_equal corrected, entry.reload.transacted_at

    entry.update!(transacted_at_local: "")
    entry.lock_saved_attributes!
    assert_no_difference "Entry.count" do
      import_csv([ value ])
    end
    assert_nil entry.reload.transacted_at
  end

  test "CSV exported after a manual time correction matches without replacing its source instant" do
    source = "2026-09-17T14:48:50Z"
    entry = import_csv([ source ]).entries.first
    entry.update!(transacted_at_local: "2026-09-17T18:00:12")
    entry.lock_saved_attributes!
    corrected = entry.reload.transacted_at

    exported = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    exported.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-17,0,Synthetic merchant,#{corrected.utc.iso8601(6)}\n"
    exported.save!
    exported.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      exported.publish
    end
    assert_equal "complete", exported.status, exported.error
    assert_equal entry.id, exported.entries.first.id
    assert_equal Time.iso8601(source).utc.iso8601(6), entry.reload.transaction.extra.dig("csv", "transacted_at")
    assert_no_difference "Entry.count" do
      import_csv([ source ])
    end
    assert_equal corrected, entry.reload.transacted_at
  end

  test "CSV export matches after both accounting date and time are corrected" do
    source = "2026-09-17T14:48:50Z"
    entry = import_csv([ source ]).entries.first
    entry.update!(date: "2026-09-18", transacted_at_local: "2026-09-17T18:00:12")
    entry.lock_saved_attributes!
    corrected = entry.reload.transacted_at

    exported = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "transacted_at")
    exported.raw_file_str = exported_transaction_csv(entry)
    exported.save!
    exported.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      exported.publish
    end
    assert_equal "complete", exported.status, exported.error
    assert_equal entry.id, exported.entries.first.id
    assert_equal Date.new(2026, 9, 18), entry.reload.date
    assert_equal Time.iso8601(source).utc.iso8601(6), entry.transaction.extra.dig("csv", "transacted_at")
  end

  test "a corrected accounting date requires export identity when its source date differs" do
    source = "2026-09-17T14:48:50Z"
    entry = import_csv([ source ]).entries.first
    entry.update!(date: "2026-09-18", transacted_at_local: "2026-09-17T18:00:12")
    corrected = entry.transacted_at

    legacy = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    legacy.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-18,0,Synthetic merchant,#{corrected.utc.iso8601(6)}\n"
    legacy.save!
    legacy.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      legacy.publish
    end
    assert_equal "failed", legacy.status
    assert_match "Row 1", legacy.error
    assert_equal corrected, entry.reload.transacted_at
    assert_equal "2026-09-17", entry.transaction.extra.dig("csv", "date")
  end

  test "CSV export matches after the accounting date alone is corrected" do
    source = "2026-09-17T14:48:50Z"
    entry = import_csv([ source ]).entries.first
    entry.update!(date: "2026-09-18")
    exported = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "transacted_at")
    exported.raw_file_str = exported_transaction_csv(entry)
    exported.save!
    exported.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      exported.publish
    end
    assert_equal "complete", exported.status, exported.error
    assert_equal entry.id, exported.entries.first.id
    assert_equal "2026-09-17", entry.reload.transaction.extra.dig("csv", "date")
  end

  test "CSV timestamp matching fails when a current time and another source instant collide" do
    first = "2026-09-17T14:48:50Z"
    second = "2026-09-17T15:48:50Z"
    corrected = import_csv([ first ]).entries.first
    original = import_csv([ second ]).entries.first
    corrected.update!(transacted_at: Time.iso8601(second))

    collision = build_import
    collision.raw_file_str = "Date,Amount,Name\n#{second},0,Synthetic merchant\n"
    collision.save!
    collision.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      collision.publish
    end
    assert_equal "failed", collision.status
    assert_match "Row 1", collision.error
    assert_equal Time.iso8601(second), original.reload.transacted_at
  end

  test "CSV time correction fails when its source instant belongs to a different accounting day" do
    first = "2026-09-17T14:48:50Z"
    second = "2026-09-17T15:48:50Z"
    corrected = import_csv([ first ]).entries.first
    other = import_csv([ second ]).entries.first
    other.update!(date: "2026-09-18")
    corrected.update!(transacted_at: Time.iso8601(second))

    collision = build_import
    collision.raw_file_str = "Date,Amount,Name\n#{second},0,Synthetic merchant\n"
    collision.save!
    collision.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      collision.publish
    end
    assert_equal "failed", collision.status
    assert_match "Row 1", collision.error
    assert_equal Date.new(2026, 9, 18), other.reload.date
  end

  test "one legacy entry can gain a timestamp but ambiguous legacy matches roll back" do
    first = create_entry
    assert_no_difference "Entry.count" do
      import_csv([ "2026-09-17T14:48:50Z" ])
    end
    assert_equal Time.utc(2026, 9, 17, 14, 48, 50), first.reload.transacted_at

    legacy = Array.new(2) { create_entry(date: Date.new(2026, 9, 18)) }
    assert_no_difference "Entry.count" do
      failed = import_csv([ "2026-09-18T14:48:50Z" ], expect_success: false)
      assert_equal "failed", failed.status
      assert_match "Row 1", failed.error
    end
    assert legacy.all? { |entry| entry.reload.transacted_at.nil? }
  end

  test "one legacy entry and multiple possible incoming timestamps also require review" do
    entry = create_entry
    failed = import_csv([ "2026-09-17T14:48:50Z", "2026-09-17T15:48:50Z" ], expect_success: false)

    assert_equal "failed", failed.status
    assert_nil entry.reload.transacted_at
  end

  test "explicit accounting date and separate timestamp round trip independently" do
    import = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred", date_basis: "local")
    import.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-14,0,Synthetic merchant,2026-09-13T10:52:33Z\n"
    import.save!
    import.generate_rows_from_csv
    import.publish

    assert_equal "complete", import.status, import.error
    assert_equal Date.new(2026, 9, 14), import.entries.first.date
    assert_equal Time.utc(2026, 9, 13, 10, 52, 33), import.entries.first.transacted_at
  end

  test "local date policy uses the datetime column even with a separate occurrence timestamp" do
    import = build_import(date_format: "iso8601", date_basis: "local", timestamp_col_label: "Occurred")
    import.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-17T23:30:00Z,0,Synthetic merchant,2026-09-17T10:52:33Z\n"
    import.save!

    assert_equal Date.new(2026, 9, 18), import.date_preview.date
    import.generate_rows_from_csv
    import.publish

    assert_equal "complete", import.status, import.error
    assert_equal Date.new(2026, 9, 18), import.entries.first.date
    assert_equal Time.utc(2026, 9, 17, 10, 52, 33), import.entries.first.transacted_at
  end

  test "a blank selected timestamp never falls back to another timestamp column" do
    import = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    import.raw_file_str = "Date,Amount,Name,Occurred,transacted_at\n2026-09-17,0,Synthetic merchant,,2026-09-17T14:48:50Z\n"
    import.save!

    assert_nil import.date_preview.timestamp
    import.generate_rows_from_csv
    assert_equal "", import.rows.first.transacted_at
    import.publish
    assert_equal "complete", import.status, import.error
    assert_nil import.entries.first.transacted_at
  end

  test "date-only rows cannot consume another row's exact timestamp match" do
    timestamp = Time.utc(2026, 9, 17, 14, 48, 50)
    timed = create_entry(transacted_at: timestamp, created_at: 2.days.ago)
    untimed = create_entry(created_at: 1.day.ago)
    import = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred", notes_col_label: "Notes")
    import.raw_file_str = "Date,Amount,Name,Occurred,Notes\n2026-09-17,0,Synthetic merchant,,Unknown time\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,Known time\n"
    import.save!
    import.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      import.publish
    end
    assert_equal "complete", import.status, import.error
    assert_equal timestamp, timed.reload.transacted_at
    assert_equal "Known time", timed.notes
    assert_nil untimed.reload.transacted_at
    assert_equal "Unknown time", untimed.notes
  end

  test "already resolved exact matches do not make a remaining legacy match ambiguous" do
    first = create_entry(transacted_at: Time.utc(2026, 9, 17, 14, 48, 50))
    legacy = create_entry
    assert_no_difference "Entry.count" do
      import_csv([ "2026-09-17T14:48:50Z", "2026-09-17T15:48:50Z" ])
    end
    assert_equal Time.utc(2026, 9, 17, 14, 48, 50), first.reload.transacted_at
    assert_equal Time.utc(2026, 9, 17, 15, 48, 50), legacy.reload.transacted_at
  end

  test "a separate accounting date restricts legacy matching to that date" do
    other_day = create_entry(date: "2026-09-17")
    import = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    import.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-18,0,Synthetic merchant,2026-09-17T14:48:50Z\n"
    import.save!
    import.generate_rows_from_csv
    assert_difference "Entry.count", 1 do
      import.publish
    end
    assert_equal "complete", import.status, import.error
    assert_nil other_day.reload.transacted_at
    assert_equal Date.new(2026, 9, 18), import.entries.first.date
  end

  test "a legacy match on an explicit date is not ambiguous with a different accounting day" do
    other_day = create_entry(date: "2026-09-17")
    expected = create_entry(date: "2026-09-18")
    import = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    import.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-18,0,Synthetic merchant,2026-09-17T14:48:50Z\n"
    import.save!
    import.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      import.publish
    end
    assert_equal "complete", import.status, import.error
    assert_equal Time.utc(2026, 9, 17, 14, 48, 50), expected.reload.transacted_at
    assert_nil other_day.reload.transacted_at
  end

  test "local accounting date cannot claim a date-only entry from the UTC day" do
    other_day = create_entry(date: "2026-09-17")
    assert_difference "Entry.count", 1 do
      import = import_csv([ "2026-09-17T23:30:00Z" ], date_basis: "local")
      assert_equal Date.new(2026, 9, 18), import.entries.first.date
    end
    assert_nil other_day.reload.transacted_at
  end

  test "a legacy match uses the chosen accounting date even across midnight" do
    other_day = create_entry(date: "2026-09-17")
    expected = create_entry(date: "2026-09-18")
    assert_no_difference "Entry.count" do
      import_csv([ "2026-09-17T23:30:00Z" ], date_basis: "local")
    end
    assert_equal Time.utc(2026, 9, 17, 23, 30), expected.reload.transacted_at
    assert_nil other_day.reload.transacted_at
  end

  test "timestamp matching is scoped to the account" do
    other = accounts(:credit_card)
    original = create_entry(account: other, transacted_at: Time.utc(2026, 9, 17, 14, 48, 50))
    assert_difference "Entry.count", 1 do
      import_csv([ "2026-09-17T14:48:50Z" ])
    end
    assert_nil original.reload.import_id
  end

  test "ordering keeps unknown times stable and preserves valuation precedence" do
    unknown_old = create_entry(created_at: 2.days.ago)
    late = create_entry(transacted_at: Time.utc(2026, 9, 17, 18))
    unknown_new = create_entry(created_at: 1.day.ago)
    early = create_entry(transacted_at: Time.utc(2026, 9, 17, 9))
    valuation = @account.entries.create!(date: early.date, amount: 100, currency: "USD", name: "Valuation", entryable: Valuation.new)
    scope = Entry.where(id: [ unknown_old, late, unknown_new, early, valuation ].map(&:id))

    expected = [ valuation, late, early, unknown_new, unknown_old ].map(&:id)
    assert_equal expected, scope.reverse_chronological.pluck(:id)
    assert_equal expected.reverse, scope.chronological.pluck(:id)
  end

  test "accounting date edits and unrelated updates preserve timestamp precision" do
    entry = create_entry(transacted_at: Time.iso8601("2026-09-17T14:48:50.123456Z"))
    instant = entry.transacted_at
    entry.update!(date: "2026-09-18", notes: "A note")
    assert_equal instant, entry.reload.transacted_at
  end

  test "invalid local timestamps and DST gaps do not overwrite an entry" do
    entry = create_entry(transacted_at: Time.utc(2026, 9, 17, 14))
    assert_not entry.update(transacted_at_local: "2026-02-30T12:00")
    assert_includes entry.errors.attribute_names, :transacted_at_local
    entry.reload
    assert_not entry.update(transacted_at_local: "2026-03-29T02:30:00")
    assert_equal Time.utc(2026, 9, 17, 14), entry.reload.transacted_at
  end

  test "unchanged browser values preserve microseconds and the original DST occurrence" do
    instant = Time.iso8601("2026-09-17T14:48:50.120456Z")
    entry = create_entry(transacted_at: instant)
    assert_equal "2026-09-17T16:48:50", entry.transacted_at_local
    entry.update!(transacted_at_local: "2026-09-17T16:48:50")
    assert_equal instant, entry.reload.transacted_at
    entry.lock_saved_attributes!
    assert_not entry.locked?(:transacted_at)

    entry.update!(transacted_at_local: "2026-09-17T16:48:51")
    assert_equal Time.utc(2026, 9, 17, 14, 48, 51), entry.reload.transacted_at

    later_occurrence = Time.utc(2026, 10, 25, 1, 30)
    entry.update!(transacted_at: later_occurrence)
    entry.update!(transacted_at_local: "2026-10-25T02:30")
    assert_equal later_occurrence, entry.reload.transacted_at
  end

  test "explicit offset with surrounding whitespace selects the requested DST occurrence" do
    entry = create_entry(transacted_at: Time.utc(2026, 10, 25, 1, 30))

    entry.update!(transacted_at_local: "2026-10-25T02:30:00+02:00 ")

    assert_equal Time.utc(2026, 10, 25, 0, 30), entry.reload.transacted_at
  end

  test "split children inherit timestamps and cannot independently change them" do
    parent = create_entry(amount: 10, transacted_at: Time.utc(2026, 9, 17, 14))
    children = parent.split!([ { name: "One", amount: 4 }, { name: "Two", amount: 6 } ])
    assert children.all? { |child| child.transacted_at == parent.transacted_at }
    assert_not children.first.update(transacted_at: Time.utc(2026, 9, 17, 15))
    parent.update!(transacted_at: Time.utc(2026, 9, 17, 16))
    assert children.all? { |child| child.reload.transacted_at == parent.transacted_at }
  end

  test "corrected split children still match their original CSV timestamp" do
    original_time = "2026-09-17T14:48:50Z"
    parent = import_csv([ original_time ]).entries.first
    children = parent.split!([ { name: "One", amount: 0 }, { name: "Two", amount: 0 } ])
    parent.update!(transacted_at_local: "2026-09-17T18:00:12")
    parent.lock_saved_attributes!

    reimport = build_import
    reimport.raw_file_str = "Date,Amount,Name\n#{original_time},0,One\n#{original_time},0,Two\n"
    reimport.save!
    reimport.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal children.map(&:id).sort, reimport.entries.pluck(:id).sort
    assert children.all? { |child| child.reload.transacted_at == parent.transacted_at }
  end

  test "children split before their first CSV timestamp retain provenance on reimport" do
    original_time = "2026-09-17T14:48:50Z"
    parent = import_csv([ "2026-09-17" ], date_format: "%Y-%m-%d").entries.first
    children = parent.split!([ { name: "One", amount: 0 }, { name: "Two", amount: 0 } ])
    import_csv([ original_time ])
    assert children.all? { |child| child.reload.transaction.extra.dig("csv", "date") == "2026-09-17" }
    parent.reload.update!(transacted_at_local: "2026-09-17T18:00:12")
    parent.lock_saved_attributes!

    reimport = build_import
    reimport.raw_file_str = "Date,Amount,Name\n#{original_time},0,One\n#{original_time},0,Two\n"
    reimport.save!
    reimport.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal children.map(&:id).sort, reimport.entries.pluck(:id).sort
  end

  test "identical CSV instants use their explicit accounting date when matching" do
    original_time = "2026-09-17T14:48:50Z"
    instant = Time.iso8601(original_time)
    extra = { "csv" => { "transacted_at" => instant.utc.iso8601(6) } }
    first = create_entry(transacted_at: instant, entryable: Transaction.new(extra: extra))
    second = create_entry(date: "2026-09-18", transacted_at: instant, entryable: Transaction.new(extra: extra))
    reimport = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred", notes_col_label: "Notes")
    reimport.raw_file_str = "Date,Amount,Name,Occurred,Notes\n2026-09-18,0,Synthetic merchant,#{original_time},Second day\n2026-09-17,0,Synthetic merchant,#{original_time},First day\n"
    reimport.save!
    reimport.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal "First day", first.reload.notes
    assert_equal "Second day", second.reload.notes
  end

  test "same-date timestamp matches take priority across the whole CSV batch" do
    original_time = "2026-09-17T14:48:50Z"
    instant = Time.iso8601(original_time)
    existing = create_entry(transacted_at: instant, entryable: Transaction.new(extra: { "csv" => { "transacted_at" => instant.utc.iso8601(6) } }))
    reimport = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred", notes_col_label: "Notes")
    reimport.raw_file_str = "Date,Amount,Name,Occurred,Notes\n2026-09-18,0,Synthetic merchant,#{original_time},Second day\n2026-09-17,0,Synthetic merchant,#{original_time},First day\n"
    reimport.save!
    reimport.generate_rows_from_csv

    assert_difference "Entry.count", 1 do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal "First day", existing.reload.notes
    assert_equal "Second day", reimport.entries.find_by!(date: "2026-09-18").notes
  end

  test "a single row on another explicit date cannot claim a different CSV transaction" do
    first = import_csv([ "2026-09-17T14:48:50Z" ]).entries.first
    reimport = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    reimport.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-18,0,Synthetic merchant,2026-09-17T14:48:50Z\n"
    reimport.save!
    reimport.generate_rows_from_csv

    assert_difference "Entry.count", 1 do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal Date.new(2026, 9, 17), first.reload.date
    assert_equal Date.new(2026, 9, 18), reimport.entries.first.date
  end

  test "a different source date cannot claim a manually corrected current timestamp" do
    original = import_csv([ "2026-09-16T10:00:00Z" ]).entries.first
    original.update!(date: "2026-09-17", transacted_at_local: "2026-09-17T16:48:50")
    original.lock_saved_attributes!

    incoming = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred", notes_col_label: "Notes")
    incoming.raw_file_str = "Date,Amount,Name,Occurred,Notes\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,Wrong entry\n"
    incoming.save!
    incoming.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      incoming.publish
    end
    assert_equal "failed", incoming.status
    assert_match "Row 1", incoming.error
    assert original.reload.notes.blank?
    assert_equal "2026-09-16", original.transaction.extra.dig("csv", "date")
  end

  test "a conflicting Sure export ID cannot claim a different entry" do
    first = import_csv([ "2026-09-16T10:00:00Z" ]).entries.first
    second = import_csv([ "2026-09-17T14:48:50Z" ]).entries.first
    first.update!(transacted_at: second.transacted_at)
    original_import_id = second.import_id

    incoming = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    incoming.raw_file_str = "Date,Amount,Name,Occurred,sure_entry_id\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,#{first.id}\n"
    incoming.save!
    incoming.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      incoming.publish
    end
    assert_equal "failed", incoming.status
    assert_match "Row 1", incoming.error
    assert_equal original_import_id, second.reload.import_id
  end

  test "unknown Sure export IDs do not claim matching entries in the selected account" do
    original = import_csv([ "2026-09-16T10:00:00Z" ]).entries.first
    original.update!(date: "2026-09-17", transacted_at: Time.utc(2026, 9, 17, 14, 48, 50))

    incoming = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    incoming.raw_file_str = "Date,Amount,Name,Occurred,sure_entry_id\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,#{SecureRandom.uuid}\n"
    incoming.save!
    incoming.generate_rows_from_csv

    assert_difference "Entry.count", 1 do
      incoming.publish
    end
    assert_equal "complete", incoming.status, incoming.error
    created_id = incoming.entries.first.id
    assert_not_equal original.id, created_id

    repeated = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    repeated.raw_file_str = incoming.raw_file_str
    repeated.save!
    repeated.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      repeated.publish
    end
    assert_equal "complete", repeated.status, repeated.error
    assert_equal created_id, repeated.entries.first.id
  end

  test "a Sure export ID from another account cannot claim its entry" do
    other = accounts(:credit_card).entries.create!(date: "2026-09-17", transacted_at: Time.utc(2026, 9, 17, 14, 48, 50),
      amount: 0, currency: "USD", name: "Synthetic merchant", entryable: Transaction.new)
    incoming = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    incoming.raw_file_str = "Date,Amount,Name,Occurred,sure_entry_id\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,#{other.id}\n"
    incoming.save!
    incoming.generate_rows_from_csv

    assert_difference "Entry.count", 1 do
      incoming.publish
    end
    assert_equal "complete", incoming.status, incoming.error
    assert_equal @account.id, incoming.entries.first.account_id
    assert_not_equal other.id, incoming.entries.first.id
    assert_nil other.reload.import_id
  end

  test "duplicate or malformed Sure export IDs fail without updating entries" do
    original = import_csv([ "2026-09-17T14:48:50Z" ]).entries.first
    original_import_id = original.import_id

    [ "#{original.id},#{original.id.upcase}", "not-a-uuid" ].each do |identities|
      rows = identities.split(",").map do |id|
        "2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,#{id}\n"
      end.join
      incoming = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
      incoming.raw_file_str = "Date,Amount,Name,Occurred,sure_entry_id\n#{rows}"
      incoming.save!
      incoming.generate_rows_from_csv

      assert_no_difference "Entry.count" do
        incoming.publish
      end
      assert_equal "failed", incoming.status
      assert_match "Row", incoming.error
      assert_equal original_import_id, original.reload.import_id
    end
  end

  test "two Sure export IDs cannot update the same transaction in one CSV" do
    foreign_id = SecureRandom.uuid
    first = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    first.raw_file_str = "Date,Amount,Name,Occurred,sure_entry_id\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,#{foreign_id}\n"
    first.save!
    first.generate_rows_from_csv
    first.publish
    assert_equal "complete", first.status, first.error
    entry = first.entries.first

    incoming = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred", notes_col_label: "Notes")
    incoming.raw_file_str = "Date,Amount,Name,Occurred,Notes,sure_entry_id\n" \
                            "2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,First,#{foreign_id}\n" \
                            "2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,Second,#{entry.id}\n"
    incoming.save!
    incoming.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      incoming.publish
    end
    assert_equal "failed", incoming.status
    assert_match "Row 2", incoming.error
    assert entry.reload.notes.blank?
  end

  test "a Sure export ID on a split parent wins over inherited child metadata" do
    foreign_id = SecureRandom.uuid
    source = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    source.raw_file_str = "Date,Amount,Name,Occurred,sure_entry_id\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z,#{foreign_id}\n"
    source.save!
    source.generate_rows_from_csv
    source.publish
    assert_equal "complete", source.status, source.error
    parent = source.entries.first
    children = parent.split!([ { name: "One", amount: 0 }, { name: "Two", amount: 0 } ])

    repeated = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    repeated.raw_file_str = source.raw_file_str
    repeated.save!
    repeated.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      repeated.publish
    end
    assert_equal "complete", repeated.status, repeated.error
    assert_equal parent.id, repeated.entries.first.id
    assert children.all? { |child| child.reload.parent_entry_id == parent.id }
  end

  test "a corrected accounting date matches its original CSV date on reimport" do
    import = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    import.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-17,0,Synthetic merchant,2026-09-17T14:48:50Z\n"
    import.save!
    import.generate_rows_from_csv
    import.publish
    entry = import.entries.first
    entry.update!(date: "2026-09-18")

    reimport = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    reimport.raw_file_str = import.raw_file_str
    reimport.save!
    reimport.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal entry.id, reimport.entries.first.id
    assert_equal Date.new(2026, 9, 18), entry.reload.date
  end

  test "a cross-date timestamp without source-date provenance requires review" do
    instant = Time.iso8601("2026-09-17T14:48:50Z")
    original = create_entry(transacted_at: instant, entryable: Transaction.new(extra: { "csv" => { "transacted_at" => instant.utc.iso8601(6) } }))
    import = build_import(date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    import.raw_file_str = "Date,Amount,Name,Occurred\n2026-09-18,0,Synthetic merchant,2026-09-17T14:48:50Z\n"
    import.save!
    import.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      import.publish
    end
    assert_equal "failed", import.status
    assert_match "Row 1", import.error
    assert_nil original.reload.import_id
  end

  test "a cross-date match with provenance is ambiguous beside an unprovenanced match" do
    instant = Time.iso8601("2026-09-17T14:48:50Z")
    original = import_csv([ instant.iso8601 ]).entries.first
    unprovenanced = create_entry(date: "2026-09-19", transacted_at: instant)
    original.update!(date: "2026-09-18")
    reimport = build_import
    reimport.raw_file_str = "Date,Amount,Name\n#{instant.iso8601},0,Synthetic merchant\n"
    reimport.save!
    reimport.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "failed", reimport.status
    assert_match "Row 1", reimport.error
    assert_nil unprovenanced.reload.import_id
  end

  test "split children carry source-date provenance across accounting-date corrections" do
    original_time = "2026-09-17T23:30:00Z"
    parent = import_csv([ original_time ], date_basis: "local").entries.first
    children = parent.split!([ { name: "One", amount: 0 }, { name: "Two", amount: 0 } ])
    assert_equal Date.new(2026, 9, 18), children.first.date
    assert children.all? { |child| child.transaction.extra.dig("csv", "date") == "2026-09-17" }

    reimport = build_import(date_basis: "source")
    reimport.raw_file_str = "Date,Amount,Name\n#{original_time},0,One\n#{original_time},0,Two\n"
    reimport.save!
    reimport.generate_rows_from_csv

    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal children.map(&:id).sort, reimport.entries.pluck(:id).sort
  end

  private
    def exported_transaction_csv(entry)
      result = nil
      Zip::File.open_buffer(Family::DataExporter.new(entry.account.family).generate_export) do |zip|
        data = CSV.parse(zip.read("transactions.csv"), headers: true)
        selected = data.find { |row| row["sure_entry_id"] == entry.id }
        result = CSV.generate do |csv|
          csv << data.headers
          csv << selected.fields
        end
      end
      result
    end

    def create_entry(**attributes)
      Entry.create!({ account: @account, date: "2026-09-17", amount: 0, currency: "USD",
                     name: "Synthetic merchant", entryable: Transaction.new }.merge(attributes))
    end

    def build_import(**attributes)
      TransactionImport.new({ family: @account.family, account: @account,
                              date_col_label: "Date", date_format: "auto", amount_col_label: "Amount",
                              name_col_label: "Name", signage_convention: "inflows_negative" }.merge(attributes))
    end

    def import_csv(values, expect_success: true, **attributes)
      import = build_import(**attributes)
      import.raw_file_str = "Date,Amount,Name\n" + values.map { |value| "#{value},0,Synthetic merchant\n" }.join
      import.save!
      import.generate_rows_from_csv
      import.publish
      assert_equal "complete", import.status, import.error if expect_success
      import
    end
end
