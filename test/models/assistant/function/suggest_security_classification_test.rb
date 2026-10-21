require "test_helper"

# The tool writes PROPOSALS, never classifications. It is registered through
# `Assistant.function_classes`, which also feeds `/mcp` -- so it is callable by an
# external agent and re-checks the user's scope itself rather than trusting the
# caller.
class Assistant::Function::SuggestSecurityClassificationTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @security = securities(:aapl)
    @function = Assistant::Function::SuggestSecurityClassification.new(@user)
  end

  test "a proposal is recorded, and the security is left alone" do
    result = @function.call("proposals" => [ {
      "ticker" => "AAPL", "asset_class" => "equity", "asset_sub_class" => "stock",
      "sector" => "Technology", "rationale" => "Common stock listed on XNAS."
    } ])

    proposal = Security::ClassificationProposal.sole
    assert_equal @security, proposal.security
    assert_equal @family, proposal.family
    assert_equal "equity", proposal.asset_class
    assert_equal "stock", proposal.asset_sub_class
    assert_equal "Technology", proposal.sector
    assert_equal "Common stock listed on XNAS.", proposal.rationale
    assert proposal.pending?

    assert_nil @security.reload.asset_class, "the tool classified a security directly"
    assert_equal 1, result[:recorded]
    assert_empty result[:skipped]
  end

  test "the ticker is matched without regard to case" do
    result = @function.call("proposals" => [ { "ticker" => "aapl", "region" => "north_america" } ])

    assert_equal 1, result[:recorded]
    assert_equal @security, Security::ClassificationProposal.sole.security
  end

  # The tool is reachable over /mcp, so the ticker is resolved within the user's
  # own holdings rather than across the table. Otherwise an external caller
  # could queue a proposal against an instrument this family does not hold.
  test "a ticker the family does not hold is refused" do
    Security.create!(ticker: "NVDA", exchange_operating_mic: "XNAS", country_code: "US")

    result = @function.call("proposals" => [ {
      "ticker" => "NVDA", "asset_class" => "equity"
    } ])

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
    assert_match(/not held/i, result[:skipped].first[:reason])
  end

  # The family holds AAPL, but only in the admin's own investment account, which
  # is not shared with this member. The admin is allowed through above; the
  # member must not be, or the tool would reveal and act on a position the
  # member cannot open.
  test "a security held only in an account the user cannot see is refused" do
    member = users(:family_member)
    assert_not member.accessible_accounts.exists?(accounts(:investment).id), "precondition: the member cannot see the account"

    result = Assistant::Function::SuggestSecurityClassification.new(member).call("proposals" => [ {
      "ticker" => "AAPL", "asset_class" => "equity"
    } ])

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
    assert_match(/not held/i, result[:skipped].first[:reason])
  end

  test "a security held only in an account pending deletion is refused" do
    accounts(:investment).update_columns(status: "pending_deletion")

    result = @function.call("proposals" => [ { "ticker" => "AAPL", "asset_class" => "equity" } ])

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
  end

  test "a security the user has already classified is skipped, with a reason" do
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    result = @function.call("proposals" => [ {
      "ticker" => "AAPL", "asset_class" => "equity"
    } ])

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
    assert_match(/by hand/i, result[:skipped].first[:reason])
  end

  # `propose!` updates an existing proposal in place, and the model's
  # manual/locked veto runs on create only. So once a proposal exists, the
  # tool's own pre-check is what keeps a re-proposal from reviving it after
  # the user answered the security by hand.
  test "re-proposing for a security classified by hand since is skipped" do
    @function.call("proposals" => [ { "ticker" => "AAPL", "asset_class" => "equity" } ])
    existing = Security::ClassificationProposal.sole
    existing.update!(status: "rejected")
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    # A fresh call, as a later chat turn or MCP request would make.
    result = Assistant::Function::SuggestSecurityClassification.new(@user).call(
      "proposals" => [ { "ticker" => "AAPL", "asset_class" => "equity" } ]
    )

    assert_equal 0, result[:recorded]
    assert_equal "rejected", existing.reload.status, "a re-proposal revived a proposal the user had answered"
    assert_match(/by hand/i, result[:skipped].first[:reason])
  end

  test "an invalid value is skipped rather than raising" do
    result = nil
    assert_nothing_raised do
      result = @function.call("proposals" => [ {
        "ticker" => "AAPL", "asset_class" => "nonsense"
      } ])
    end

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
    assert_equal [ "AAPL" ], result[:skipped].map { |entry| entry[:ticker] }
  end

  # The schema requires only `ticker`, so the model can send exactly this shape.
  # Recording it would let approval stamp "ai" on a security with nothing
  # classified.
  test "a proposal that answers nothing is skipped" do
    result = @function.call("proposals" => [ { "ticker" => "AAPL", "sector" => "", "rationale" => "No idea." } ])

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
    assert_match(/at least one/i, result[:skipped].first[:reason])
  end

  # `propose!` writes with a bang, and the pre-check makes a failure there
  # unlikely rather than impossible -- it updates an existing row, so a
  # validation that depends on persisted state can still refuse. Unrescued, the
  # user would lose every proposal after the bad one.
  test "a security that cannot be recorded does not cost the user the rest of the batch" do
    other = Security.create!(ticker: "MSFT9", exchange_operating_mic: "XNAS", country_code: "US")
    accounts(:investment).holdings.create!(
      security: other, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD"
    )

    # The first ticker refuses at write time; the second must still land.
    Security::ClassificationProposal.stubs(:propose!).raises(
      ActiveRecord::RecordInvalid.new(Security::ClassificationProposal.new)
    ).then.returns(Security::ClassificationProposal.new)

    result = @function.call("proposals" => [
      { "ticker" => "AAPL", "asset_class" => "equity", "asset_sub_class" => "stock" },
      { "ticker" => "MSFT9", "asset_class" => "equity", "asset_sub_class" => "stock" }
    ])

    assert_equal 1, result[:recorded], "the batch stopped at the first security it could not record"
    assert_equal [ "AAPL" ], result[:skipped].map { |entry| entry[:ticker] }
  end

  test "the tool is offered to preview users only" do
    assert_includes Assistant::PREVIEW_FUNCTION_CLASSES,
                    Assistant::Function::SuggestSecurityClassification

    plain = users(:family_member)
    assert_not plain.preview_features_enabled?, "precondition: the plain user has not opted in"
    assert_not_includes Assistant.function_classes(plain), Assistant::Function::SuggestSecurityClassification,
                        "a preview tool reached the default surface, which /mcp also serves"

    # The positive half. Membership of PREVIEW_FUNCTION_CLASSES is not the same
    # as the gate letting a preview user through.
    preview_user = users(:family_admin)
    preview_user.update!(preferences: (preview_user.preferences || {}).merge("preview_features_enabled" => true))

    assert_includes Assistant.function_classes(preview_user.reload),
                    Assistant::Function::SuggestSecurityClassification,
                    "the gate did not offer the tool to a preview user"
  end

  # A proposal replaces the family's pending one for that security, so a guest,
  # who may view the family's setup but not change it, must not be able to
  # overwrite a member's. The registry feeds chat and /mcp alike.
  test "a guest is not offered the tool, even with preview features on" do
    guest = users(:intro_user)
    assert guest.guest?, "precondition: the fixture is a guest"
    guest.update!(preferences: (guest.preferences || {}).merge("preview_features_enabled" => true))

    assert_not_includes Assistant.function_classes(guest.reload), Assistant::Function::SuggestSecurityClassification
  end
end
