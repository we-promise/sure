require "test_helper"

# Every controller action that starts an AI feature declares `requires_ai` for it, and the guard
# reads nothing but Ai.availability.
class AiFeatureGuardTest < ActiveSupport::TestCase
  # "Controller#action" => the feature it starts.
  AI_ACTIONS = {
    "Bills::SmartConfigurationsController#show" => :bill_setup,
    "RecurringTransactions::SmartFillsController#create" => :bill_setup,
    "FamilyMerchantsController#enhance" => :enhance_merchants
  }.freeze

  # Chat's entry points keep chat's own checks, not `requires_ai :chat`. The list may only shrink.
  CHAT_ALLOWLIST = %w[
    ChatsController#create
    ChatsController#retry
    MessagesController#create
    ChatReservationsController#create
    Api::V1::ChatsController#create
    Api::V1::MessagesController#create
    Bills::AiReviewsController#create
  ].freeze

  # What a controller has to mention to start an AI feature. A new one needs its action above.
  AI_STARTERS = /RecurringTransaction::AiSetupSuggester|ProviderMerchant::Enhancer\.enhance_later|Ai::GenerationJob/

  AI_ACTIONS.each do |action, feature|
    test "#{action} requires #{feature}" do
      controller, name = action.split("#")
      klass = controller.constantize
      options = klass.include?(AiFeatureGuard) && klass.ai_requirements[feature]

      assert options, "#{controller} should declare `requires_ai :#{feature}`"
      assert applies_to?(options, name), "#{controller}'s `requires_ai :#{feature}` should cover ##{name}"
    end
  end

  test "every controller that starts an AI feature is listed" do
    starters = Dir[Rails.root.join("app/controllers/**/*_controller.rb")].select { File.read(_1).match?(AI_STARTERS) }
    listed = AI_ACTIONS.keys.map { _1.split("#").first.underscore }

    starters.each do |path|
      name = path.delete_prefix(Rails.root.join("app/controllers/").to_s).delete_suffix(".rb")
      assert_includes listed, name, "#{name} starts an AI feature; add its action to AI_ACTIONS and declare requires_ai"
    end
  end

  test "chat's allowlisted controllers exist and don't use requires_ai yet" do
    CHAT_ALLOWLIST.each do |action|
      klass = action.split("#").first.constantize
      assert_not klass.include?(AiFeatureGuard) && klass.ai_requirements.key?(:chat),
                 "#{action} declares requires_ai :chat; remove it from CHAT_ALLOWLIST"
    end
  end

  test "the guard reads nothing but Ai.availability" do
    source = File.read(Rails.root.join("app/controllers/concerns/ai_feature_guard.rb"))
    body = source[/def require_ai!.*?\n    end\n/m]

    assert_includes body, "Ai.availability("
    assert_no_match(/Provider::|Setting\.|ENV\[|ai_enabled|VectorStore/, body)
  end

  private
    def applies_to?(options, action)
      only = Array(options[:only]).map(&:to_s)
      except = Array(options[:except]).map(&:to_s)
      (only.empty? || only.include?(action)) && !except.include?(action)
    end
end
