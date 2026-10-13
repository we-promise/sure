require "test_helper"

# Regression for Jimata review 5200022044 on PR #3551.
#
# The sidebar scroll-preserve inline script re-opens the account groups a user
# had open before a Turbo navigation, so the restored sidebar has enough height
# to hold the saved scrollTop. It validates each derived group key against an
# accepted-key set. That set was originally a hardcoded 6-key regex
# (credit_card|depository|investment|loan|property|vehicle) that silently
# dropped three of the nine Accountable::TYPES — crypto, other_asset, and
# other_liability — so an open group of one of those types was never re-opened
# and the restored scrollTop could be clamped.
#
# The fix derives the accepted set from Accountable::TYPES.map(&:underscore) at
# render time. This test guards that: the rendered set must equal the full set
# of accountable types (order-independent), and must include each of the three
# previously-omitted keys. It is a fast, browser-free integration test, so it
# cannot flake the way a headless Turbo-navigation system test would.
class SidebarScrollPreserveKeysTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  # Pull the `new Set([...])` argument out of the rendered inline script.
  # Anchored on the unique GROUP_KEYS variable so we never match an unrelated
  # `new Set([...])` from another inlined script earlier in the page.
  def group_keys_from(body)
    match = body.match(/GROUP_KEYS = new Set\((\[[^\]]*\])\)/)
    assert match, "expected the sidebar scroll-preserve script's GROUP_KEYS Set in the layout"
    JSON.parse(match[1])
  end

  test "accepted group keys are derived from Accountable::TYPES (all nine)" do
    get root_path
    assert_response :ok

    expected = Accountable::TYPES.map(&:underscore)
    rendered = group_keys_from(response.body)

    assert_equal expected.to_set, rendered.to_set,
      "GROUP_KEYS must equal Accountable::TYPES.map(&:underscore)"
  end

  test "the three previously-omitted group keys are accepted" do
    get root_path
    assert_response :ok

    rendered = group_keys_from(response.body)

    # The exact keys the old 6-key GROUP_RE dropped.
    [ "crypto", "other_asset", "other_liability" ].each do |key|
      assert_includes rendered, key,
        "GROUP_KEYS must include #{key.inspect} (dropped by the old 6-key regex)"
    end
  end
end
