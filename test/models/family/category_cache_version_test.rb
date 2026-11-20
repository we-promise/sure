require "test_helper"

class Family::CategoryCacheVersionTest < ActiveSupport::TestCase
  test "entry cache versions change when a category below the maximum timestamp is deleted" do
    family = families(:dylan_family)
    older = family.categories.create!(
      name: "Older cache category", color: "#0d9488", lucide_icon: "tag",
      updated_at: 2.days.ago
    )
    newest = family.categories.create!(
      name: "Newest cache category", color: "#0d9488", lucide_icon: "tag",
      updated_at: 1.hour.from_now
    )
    family.categories.load
    before = entry_versions(family)
    entry_timestamp = family.entries.maximum(:updated_at)

    older.destroy!

    assert_equal newest.reload.updated_at, family.categories.maximum(:updated_at)
    assert_equal entry_timestamp, family.entries.maximum(:updated_at)
    assert_versions_changed before, family
  end

  test "entry cache versions change for category metadata updates within one second" do
    family = families(:dylan_family)
    first_time = Time.utc(2030, 1, 1, 12, 0, 0, 123_456)
    category = travel_to(first_time, with_usec: true) do
      family.categories.create!(
        name: "Category metadata cache", color: "#0d9488", lucide_icon: "tag"
      )
    end
    before = entry_versions(family)
    original_timestamp = category.updated_at
    entry_timestamp = family.entries.maximum(:updated_at)

    travel_to(first_time + 0.0001, with_usec: true) do
      category.update!(color: "#4da568")
    end

    assert_equal original_timestamp.to_i, category.reload.updated_at.to_i
    assert_equal entry_timestamp, family.entries.maximum(:updated_at)
    assert_versions_changed before, family
  end

  test "another family's category changes do not change entry cache versions" do
    family = families(:dylan_family)
    unrelated_family = families(:empty)
    before = entry_versions(family)
    category = unrelated_family.categories.create!(
      name: "Unrelated cache category", color: "#0d9488", lucide_icon: "tag"
    )
    assert_equal before, entry_versions(family)

    travel 1.second do
      category.update!(color: "#4da568")
    end
    assert_equal before, entry_versions(family)

    category.destroy!
    assert_equal before, entry_versions(family)
  end

  private
    def entry_versions(family)
      [ family.entries_cache_version, family.entries_version ]
    end

    def assert_versions_changed(before, family)
      after = entry_versions(family)
      before.zip(after).each { |previous, current| assert_not_equal previous, current }
    end
end
