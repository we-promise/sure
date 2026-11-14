require "test_helper"

class Ai::Generations::SuggestBillSetupTest < ActiveSupport::TestCase
  def generation(current_config: nil)
    Ai::Generations::SuggestBillSetup.new(charges: [ { date: "2026-10-01", amount: "15.99", name: "NETFLIX" } ],
                                          categories: %w[Entertainment], current_config:, family: nil)
  end

  test "configure mode is a prompt local" do
    assert_equal false, generation.prompt_locals[:configure_mode]
    assert_equal true, generation(current_config: { name: "Netflix" }).prompt_locals[:configure_mode]
  end

  test "an answer outside the presets or ranges comes back as no proposal; confidence is left to clamp" do
    value = generation.coerce({ "frequency" => "fortnightly", "day_of_month" => 45, "confidence" => 3.5, "autopay" => false })

    assert_nil value[:frequency]
    assert_nil value[:day_of_month]
    assert_equal 3.5, value[:confidence]
    assert_equal false, value[:autopay]
  end

  test "null is a normal answer, so auto mode never moves on for blanks" do
    assert_nil generation.blank_item_check
  end
end
