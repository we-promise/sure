require "test_helper"

class TaggingTest < ActiveSupport::TestCase
  test "a tag cannot be applied twice to the same transaction" do
    assert_raises ActiveRecord::RecordNotUnique do
      Tagging.create!(tag: tags(:one), taggable: transactions(:one))
    end
  end

  # Postgres treats NULLs as distinct in a unique index by default, which
  # would let this duplicate through.
  test "a tag cannot be applied twice to a taggable with no type" do
    row = {
      tag_id: tags(:one).id, taggable_id: transactions(:transfer_out).id,
      taggable_type: nil, created_at: Time.current, updated_at: Time.current
    }
    Tagging.insert_all!([ row ])

    assert_raises ActiveRecord::RecordNotUnique do
      Tagging.insert_all!([ row ])
    end
  end

  test "the same tag can still be applied to different transactions" do
    assert_difference -> { Tagging.count }, 1 do
      Tagging.create!(tag: tags(:one), taggable: transactions(:transfer_out))
    end
  end
end
