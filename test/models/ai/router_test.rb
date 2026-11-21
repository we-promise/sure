require "test_helper"

class Ai::RouterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @user.update!(ai_enabled: true)
  end

  test "the switch is the column, not whether chat works" do
    @family.update!(assistant_type: "mcp_only")

    use_ai_routes
    assert Ai.available?(:bill_setup, family: @family, user: @user)
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
                            routes: { chat: [ Ai::Route.new(feature: :chat, model:) ] })
    @family.update!(assistant_type: "external")

    assert_equal :not_configured, Ai::Router.new(family: @family, user: @user, config:).resolve(:chat).reason
    @user.email = "Someone@example.com"
    assert_kind_of Ai::Plan, Ai::Router.new(family: @family, user: @user, config:).resolve(:chat)
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
  test "PDF import with only an OCR model isn't available: something has to read the transcription" do
    endpoint = ai_endpoint(name: "mistral", preset: :mistral, base_url: nil)
    ocr = ai_model(name: "mistral-ocr-latest", endpoint:, capabilities: %i[ocr])
    Ai::Config.override = AiTestHelper.build_ai_config([ ocr ], { extract_pdf: [ "mistral/mistral-ocr-latest" ] })

    assert_equal :capability_missing, Ai.availability(:extract_pdf, family: @family, user: @user).reason
  end
end
