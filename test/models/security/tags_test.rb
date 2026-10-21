require "test_helper"

# A security row is shared by every family that holds the instrument, while a
# tag belongs to one family. These tests pin that tagging a security stays
# family-scoped: one family's edit never reads, attaches or removes another
# family's tags on the same row.
class Security::TagsTest < ActiveSupport::TestCase
  setup do
    @security = securities(:aapl)
    @family = families(:dylan_family)
    @tag = tags(:one)
    @second_tag = tags(:two)
    @other_family = families(:empty)
    @other_tag = @other_family.tags.create!(name: "Another household's scheme")
  end

  test "set_tags_for attaches the family's tag and the tag reaches the security" do
    assert_difference -> { Tagging.where(taggable: @security).count }, 1 do
      @security.set_tags_for(@family, [ @tag.id ])
    end

    assert_equal [ @tag ], @security.tags.to_a
    assert_equal [ @security ], @tag.securities.to_a
  end

  # The security is shared, so attaching a tag the family does not own would
  # put that tag's name on an instrument other families hold.
  test "a tag belonging to another family is not attached" do
    assert_no_difference -> { Tagging.where(taggable: @security).count } do
      @security.set_tags_for(@family, [ @other_tag.id ])
    end

    assert_empty @security.reload.tags
  end

  # security.tags spans every family, so a wholesale `tags =` assignment
  # would remove the other family's tagging along with this family's.
  test "set_tags_for leaves another family's tags on the security alone" do
    @security.taggings.create!(tag: @other_tag)

    @security.set_tags_for(@family, [ @tag.id ])

    assert_equal [ @other_tag, @tag ].sort_by(&:id), @security.reload.tags.sort_by(&:id)
  end

  test "an empty selection clears this family's tags but not another family's" do
    @security.taggings.create!(tag: @tag)
    @security.taggings.create!(tag: @other_tag)

    @security.set_tags_for(@family, [ "" ])

    assert_equal [ @other_tag ], @security.reload.tags.to_a
  end

  test "a tag left out of the selection is removed and the kept one is untouched" do
    kept = @security.taggings.create!(tag: @tag)
    @security.taggings.create!(tag: @second_tag)

    @security.set_tags_for(@family, [ @tag.id ])

    assert_equal [ kept.id ], Tagging.where(taggable: @security).pluck(:id)
  end

  test "re-submitting the same tag keeps the one existing tagging" do
    existing = @security.taggings.create!(tag: @tag)

    @security.set_tags_for(@family, [ @tag.id, @tag.id ])

    assert_equal [ existing.id ], Tagging.where(taggable: @security).pluck(:id)
  end

  # The removal runs through a query rather than the loaded association, so
  # without a reset a caller that had already loaded the tags would still
  # see the removed one.
  test "already loaded associations reflect the write without a reload" do
    @security.taggings.create!(tag: @tag)
    @security.taggings.load
    @security.tags.load

    @security.set_tags_for(@family, [ @second_tag.id ])

    assert_equal [ @second_tag.id ], @security.taggings.map(&:tag_id)
    assert_equal [ @second_tag ], @security.tags.to_a
  end

  test "destroying a tag removes its security taggings and keeps the security" do
    @security.taggings.create!(tag: @tag)

    assert_difference -> { Tagging.where(taggable: @security).count }, -1 do
      @tag.destroy!
    end

    assert Security.exists?(@security.id)
  end

  test "destroying a security removes its taggings and keeps the tags" do
    security = Security.create!(ticker: "TAGD", name: "Tagged", exchange_operating_mic: "XNAS")
    security.set_tags_for(@family, [ @tag.id ])

    assert_difference -> { Tagging.where(taggable_type: "Security", taggable_id: security.id).count }, -1 do
      security.destroy!
    end

    assert Tag.exists?(@tag.id)
  end

  # Merging two tags that are both on the same security keeps one tagging:
  # the unique index on taggings would otherwise refuse the move.
  test "merging two tags on the same security leaves one tagging" do
    @security.set_tags_for(@family, [ @tag.id, @second_tag.id ])

    @tag.replace_and_destroy!(@second_tag)

    assert_equal [ @second_tag.id ], Tagging.where(taggable: @security).pluck(:tag_id)
  end

  test "a family's data reset removes its security tags and keeps another family's" do
    @security.set_tags_for(@family, [ @tag.id ])
    @security.set_tags_for(@other_family, [ @other_tag.id ])
    Provider::Registry.stubs(:plaid_provider_for_region).returns(nil)

    Family::FinancialDataReset.new(user: users(:family_admin), dry_run: false, confirmed: true).call

    assert_equal [ @other_tag.id ], Tagging.where(taggable: @security).pluck(:tag_id)
  end

  # The security's row lock does not cover the tags, so the wanted tags are
  # read FOR SHARE: a concurrent delete of one of them then waits for this
  # write instead of failing its insert. A race can't be staged reliably in a
  # test, so this pins the lock itself.
  test "the wanted tags are read under a share lock" do
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    @security.set_tags_for(@family, [ @tag.id ])

    assert statements.any? { |sql| sql.include?(%("tags")) && sql.include?("FOR SHARE") },
           "expected the wanted tags to be read FOR SHARE"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
