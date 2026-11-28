require "test_helper"

class Insight::GeneratorTest < ActiveSupport::TestCase
  include InsightTestHelper

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

  # Insight.about_shared_accounts recomputes this digest in SQL on every read;
  # rows written before it existed were hashed in Ruby, so both must agree.
  test "the digest matches the one first computed in Ruby" do
    assert_equal ruby_shared_accounts_digest(@family), @generator.digest
  end

  # The digest describes the ids the figures were computed from, not the
  # rows still there when it is taken.
  test "an account deleted after the figures still counts in the digest" do
    first_ids = @generator.figure_account_ids

    accounts(:depository).destroy!

    assert_equal Digest::SHA256.hexdigest(first_ids.sort.join(",")), @generator.digest
  end

  test "the digest of no shared account is the hash of an empty string" do
    AccountShare.where(account: @family.accounts).delete_all

    assert_equal Digest::SHA256.hexdigest(""), @generator.digest
  end
end
