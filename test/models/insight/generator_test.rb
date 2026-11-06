require "test_helper"

class Insight::GeneratorTest < ActiveSupport::TestCase
  # Exposes the shared-account helpers the way a generator uses them: figures
  # first, the digest for the metadata afterwards.
  class ProbeGenerator < Insight::Generator
    def figure_account_ids
      shared_accounts.pluck(:id)
    end

    def digest
      shared_accounts_digest
    end
  end

  setup do
    @family = families(:dylan_family)
    @generator = ProbeGenerator.new(@family)
  end

  test "the digest and later figures use the account set the first figures saw" do
    first_ids = @generator.figure_account_ids
    assert_not_includes first_ids, accounts(:connected).id

    # Access changes mid-run: with the only other member inactive, the private
    # account becomes visible to every active member.
    users(:family_member).update_columns(active: false)

    assert_equal first_ids.sort, @generator.figure_account_ids.sort
    assert_equal Digest::SHA256.hexdigest(first_ids.sort.join(",")), @generator.digest
  end
end
