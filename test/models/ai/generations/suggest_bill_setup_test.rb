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

  test "fails over only to the explicitly configured routes, in order" do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    config = AiTestHelper.test_config
    gpu = config.endpoint(:gpu)
    openai = config.endpoint(:openai)
    models = [ ai_model(endpoint: gpu, name: "qwen3-8b", capabilities: %i[structured_output]),
               ai_model(endpoint: openai, name: "gpt-4.1-mini", capabilities: %i[structured_output]) ]
    plan_config = AiTestHelper.build_ai_config(models, { bill_setup: %w[gpu/qwen3-8b openai/gpt-4.1-mini] })

    Ai::Config.with(plan_config) do
      generation = Ai::Generations::SuggestBillSetup.new(
        charges: [ { date: "2026-10-01", amount: "15.99", name: "NETFLIX" },
                   { date: "2026-11-01", amount: "15.99", name: "NETFLIX" } ],
        categories: %w[Entertainment], current_config: nil, family: @family, user: @user)
      requests = stub_ai(:bill_setup) do |request|
        raise Ai::Error::Upstream, "gpu down" if request.model.endpoint.name == "gpu"

        { name: "Netflix", frequency: "monthly", day_of_month: 1, amount: 15.99, autopay: true, confidence: 0.9 }
      end

      result = generation.call

      assert result.success?
      assert_equal %w[gpu openai], requests.map { _1.model.endpoint.name }
      assert_equal "gpt-4.1-mini", result.route.model.name
      assert_equal "Netflix", result.value[:name]
    end
  end

  test "every configured route fails, everything else is never tried" do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
    config = AiTestHelper.test_config
    gpu = config.endpoint(:gpu)
    models = [ ai_model(endpoint: gpu, name: "qwen3-8b", capabilities: %i[structured_output]) ]
    plan_config = AiTestHelper.build_ai_config(models, { bill_setup: %w[gpu/qwen3-8b] })

    Ai::Config.with(plan_config) do
      generation = Ai::Generations::SuggestBillSetup.new(
        charges: [ { date: "2026-10-01", amount: "15.99", name: "NETFLIX" },
                   { date: "2026-11-01", amount: "15.99", name: "NETFLIX" } ],
        categories: %w[Entertainment], current_config: nil, family: @family, user: @user)
      requests = stub_ai(:bill_setup) { raise Ai::Error::Timeout, "still down" }

      result = generation.call

      assert_not result.success?
      assert_equal %w[gpu], requests.map { _1.model.endpoint.name }, "no route is tried that wasn't configured"
    end
  end
end
