require "test_helper"

class Ai::RouterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
  end

  test "a routed feature resolves to a plan with its lane and routes" do
    use_ai_routes(categorize: %w[gpu/qwen3-8b openai/gpt-4.1-mini])
    plan = Ai::Router.new(family: @family).resolve(:categorize)

    assert_kind_of Ai::Plan, plan
    assert_equal :background, plan.lane
    assert_equal %w[qwen3-8b gpt-4.1-mini], plan.routes.map { _1.model.name }
    assert_equal "qwen3-8b", Ai.plan(:categorize, family: @family).model.name
  end

  test "a feature with no routes is not configured, whatever the consent" do
    use_no_ai
    @user.update!(ai_enabled: false)

    assert_equal :not_configured, Ai.availability(:bill_setup, family: @family, user: @user).reason
    assert_not Ai.available?(:categorize, family: @family)
    assert_nil Ai.plan(:categorize, family: @family)
  end

  test "chat and bills need the user's own AI switch; other features don't" do
    @user.update!(ai_enabled: false)

    use_ai_routes
    assert_equal :user_disabled, Ai.availability(:chat, family: @family, user: @user).reason
    assert_equal :user_disabled, Ai.availability(:bill_setup, family: @family, user: @user).reason
    assert_equal :user_disabled, Ai.availability(:bill_setup, family: @family).reason
    assert Ai.available?(:extract_pdf, family: @family, user: @user)
    assert Ai.available?(:embed, family: @family, user: @user)
    assert Ai.available?(:search_documents, family: @family, user: @user)
    assert Ai.available?(:categorize, family: @family)
  end

  test "the switch is the column, not whether chat works" do
    @family.update!(assistant_type: "mcp_only")

    use_ai_routes
    assert Ai.available?(:bill_setup, family: @family, user: @user)
  end

  test "a model without the feature's needs is a missing capability" do
    use_ai_routes(chat: %w[gpu/qwen3-8b], extract_pdf: %w[embed/nomic-embed-text])
    assert Ai.available?(:chat, family: @family, user: @user)
    assert_equal :capability_missing, Ai.availability(:extract_pdf, family: @family, user: @user).reason
  end

  test "a judge or a structured-output model can categorize" do
    use_ai_routes(categorize: %w[jev/jev-latest])
    assert Ai.available?(:categorize, family: @family)
  end

  test "document search uses embed's route" do
    use_ai_routes(embed: [])
    assert_equal :not_configured, Ai.availability(:search_documents, family: @family, user: @user).reason
  end

  test "an agent endpoint serves chat only for families whose chat mode is external" do
    use_ai_routes(chat: %w[agent/openclaw/main])
    @family.update!(assistant_type: "builtin")
    assert_equal :not_configured, Ai.availability(:chat, family: @family, user: @user).reason

    @family.update!(assistant_type: "external")
    assert_equal "openclaw/main", Ai.plan(:chat, family: @family, user: @user).model.name

    use_ai_routes(chat: %w[openai/gpt-4.1-mini])
    assert_equal :not_configured, Ai.availability(:chat, family: @family, user: @user).reason
  end

  test "an agent endpoint serves only its allowed emails" do
    agent = Ai::Config::Endpoint.new(name: :agent, protocol: :compatible, agent: true,
                                     agent_settings: { allowed_emails: [ "someone@example.com" ] })
    model = Ai::Config::Model.new(endpoint: agent, name: "openclaw/main")
    config = Ai::Config.new(endpoints: [ agent ], models: [ model ],
                            routes: { chat: [ Ai::Route.new(feature: :chat, position: 0, model:) ] })
    @family.update!(assistant_type: "external")

    assert_equal :not_configured, Ai::Router.new(family: @family, user: @user, config:).resolve(:chat).reason
    @user.email = "Someone@example.com"
    assert_kind_of Ai::Plan, Ai::Router.new(family: @family, user: @user, config:).resolve(:chat)
  end

  test "a Jev entry serves only families that chose Jev" do
    jev = AiTestHelper.test_config.model(:jev, "jev-latest")
    llm = AiTestHelper.test_config.model(:openai, "gpt-4.1-mini")
    config = Ai::Config.new(routes: { categorize: [
      Ai::Route.new(feature: :categorize, position: 0, model: jev, condition: :jev_family),
      Ai::Route.new(feature: :categorize, position: 1, model: llm)
    ] })

    @family.update!(categorization_provider: "llm")
    assert_equal "gpt-4.1-mini", Ai::Router.new(family: @family, config:).resolve(:categorize).model.name

    @family.update!(categorization_provider: "jev")
    assert_equal "jev-latest", Ai::Router.new(family: @family, config:).resolve(:categorize).model.name
  end

  test "the message tells an instance admin what to set up and anyone else only why" do
    availability = Ai::Availability.unavailable(:enhance_merchants, :not_configured)
    admin = users(:family_admin)
    admin.stubs(:manages_instance_settings?).returns(true)
    member = users(:family_member)

    assert_includes availability.message_for(admin), "Settings"
    assert_includes availability.message_for(admin), "Merchants"
    assert_not_includes availability.message_for(member), "Settings"
    assert_nil Ai::Availability.available(:chat).message_for(member)
  end
end
