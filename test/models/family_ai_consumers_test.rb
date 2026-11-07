require "test_helper"

class FamilyAiConsumersTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @openai_user = users(:family_admin)
    @anthropic_user = users(:empty)
    @openai_family = @openai_user.family
    @anthropic_family = @anthropic_user.family
    @openai_family.create_ai_configuration!(provider: "openai", api_key: "test-openai-family-key")
    @anthropic_family.create_ai_configuration!(provider: "anthropic", api_key: "test-anthropic-family-key")
  end

  test "chat creation and availability use the owner with a different Current family" do
    [ @openai_user, @anthropic_user, @openai_user ].each do |user|
      other_user = user == @openai_user ? @anthropic_user : @openai_user
      Current.stubs(:user).returns(other_user)

      chat = user.chats.start!("Compare my spending", model: nil)

      assert_equal user.family.ai_configuration.model, chat.messages.find_by!(type: "UserMessage").ai_model
      assert_equal user == @openai_user, user.openai_configured?
      assert_equal user == @anthropic_user, user.anthropic_configured?
    end
  end

  test "OpenRouter enables family AI and supplies chat and categorization models independently of Current" do
    @openai_family.ai_configuration.update!(provider: "openrouter", model: "anthropic/claude-sonnet-4", api_key: "synthetic-router-key")
    Current.stubs(:user).returns(@anthropic_user)
    Rails.application.config.app_mode.stubs(:self_hosted?).returns(true)
    @openai_family.stubs(:effective_assistant_type).returns("builtin")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert @openai_user.ai_available?
    assert_not @openai_user.openai_configured?
    assert_not @openai_user.anthropic_configured?
    chat = @openai_user.chats.start!("My spending", model: nil)
    assert_equal "anthropic/claude-sonnet-4", chat.messages.first.ai_model
    assistant = Assistant::Builtin.new(chat)
    assert_instance_of Provider::Openrouter, assistant.get_model_provider(chat.messages.first.ai_model)
    assert_nil assistant.get_model_provider(Provider::Anthropic::DEFAULT_MODEL)
    assert_instance_of Provider::Openrouter, @openai_family.resolved_categorization_provider
    assert_equal "anthropic/claude-sonnet-4", @openai_family.categorization_model_name
    assert_equal Provider::Openai::AutoCategorizer.new(nil, custom_provider: true).instructions,
                 @openai_family.ai_prompt_default(:categorizer_openai)

    @openai_family.ai_configuration.update_column(:encrypted_api_key, "invalid-ciphertext")
    assert_not @openai_user.ai_available?
    assert_nil assistant.get_model_provider(chat.messages.first.ai_model)
  end

  test "assistant provider and error registry use the chat family without global fallback" do
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    [ @openai_user, @anthropic_user, @openai_user ].each do |user|
      Current.stubs(:user).returns(user == @openai_user ? @anthropic_user : @openai_user)
      chat = user.chats.build(title: "Provider scope")
      assistant = Assistant::Builtin.new(chat)
      model = user.family.ai_configuration.model
      expected_class = user == @openai_user ? Provider::Openai : Provider::Anthropic

      assert_instance_of expected_class, assistant.get_model_provider(model)
      assert_equal [ expected_class ], assistant.send(:registry).providers.map(&:class)
      assert_nil assistant.get_model_provider("unsupported-family-model")
    end
  end

  test "categorization and its model label follow each family rather than Current or global model" do
    with_env_overrides("CATEGORIZATION_PROVIDER" => nil, "OPENAI_MODEL" => "global-model", "ANTHROPIC_MODEL" => "global-claude") do
      [ @openai_family, @anthropic_family, @openai_family ].each do |family|
        Current.stubs(:user).returns(family == @openai_family ? @anthropic_user : @openai_user)
        expected_class = family == @openai_family ? Provider::Openai : Provider::Anthropic

        assert_instance_of expected_class, family.resolved_categorization_provider
        assert_equal family.ai_configuration.model, family.categorization_model_name

        family.categorization_provider = "jev"
        assert_instance_of expected_class, family.shadow_categorization_provider
        family.categorization_provider = "llm"
      end
    end
  end

  test "merchant and bill jobs pass their explicit family when Current belongs elsewhere" do
    [ @openai_family, @anthropic_family, @openai_family ].each do |family|
      user = family == @openai_family ? @openai_user : @anthropic_user
      Current.stubs(:user).returns(user == @openai_user ? @anthropic_user : @openai_user)
      Provider::Registry.expects(:preferred_llm_provider).with(family: family).times(3).returns(stub)

      assert_equal 0, Family::AutoMerchantDetector.new(family, transaction_ids: []).auto_detect
      ProviderMerchant::Enhancer.new(family, merchant_ids: []).batches
      assert_raises(RecurringTransaction::AiSetupSuggester::Error) do
        RecurringTransaction::AiSetupSuggester.new(family, user: user).suggest_from_entries([])
      end
    end
  end

  test "both PDF processing paths use the import family with interleaved Current users" do
    [ @openai_family, @anthropic_family, @openai_family ].each do |family|
      Current.stubs(:user).returns(family == @openai_family ? @anthropic_user : @openai_user)
      import = PdfImport.new(family: family, document_type: "bank_statement")
      import.stubs(:pdf_file_content).returns("test-pdf-bytes")
      import.stubs(:update!).returns(true)
      provider = mock("#{family.id} PDF provider")
      provider.expects(:supports_pdf_processing?).returns(true)
      provider.expects(:process_pdf).with(pdf_content: "test-pdf-bytes", family: family)
              .returns(provider_success_response(OpenStruct.new(summary: "Statement", document_type: "bank_statement")))
      provider.expects(:extract_bank_statement).with(pdf_content: "test-pdf-bytes", family: family)
              .returns(provider_success_response({ transactions: [] }))
      Provider::Registry.expects(:preferred_llm_provider).with(family: family).twice.returns(provider)

      assert_equal "Statement", import.process_with_ai.summary
      assert_equal({ "transactions" => [] }, import.extract_transactions)
    end
  end

  test "unreadable family credentials never enable an installation provider" do
    @openai_family.ai_configuration.update_column(:encrypted_api_key, "not-valid-ciphertext")
    Provider::Registry.expects(:openai).never
    Provider::Registry.expects(:anthropic).never

    assert_not @openai_user.openai_configured?
    assert_not @openai_user.anthropic_configured?
    assert_nil @openai_family.resolved_categorization_provider
  end

  test "family prompt defaults use official provider instructions despite a custom installation endpoint" do
    with_env_overrides("OPENAI_URI_BASE" => "http://localhost:11434/v1") do
      expected = Provider::Openai::AutoCategorizer.new(nil, custom_provider: false).instructions
      assert_equal expected, @openai_family.ai_prompt_default(:categorizer_openai)
      @openai_family.ai_prompt_categorizer_openai = "A custom prompt without wrapper keys"
      assert_not @openai_family.ai_prompt_format_risk?(:categorizer_openai)
    end
  end
end
