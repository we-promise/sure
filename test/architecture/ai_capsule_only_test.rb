require "test_helper"

# The check is a property of where a call runs, not of which caller meant it. A web request or
# a job outside an AI queue fails; the same call in a capsule, an AI job or an eval's outside
# block passes.
class AiCapsuleOnlyTest < ActionController::TestCase
  include ActiveJob::TestHelper

  class DefaultQueueJob < ApplicationJob
    queue_as :default

    def perform = AiCapsuleOnlyTest.call_ai
  end

  class RuleStyleJob < RuleJob
    def perform = AiCapsuleOnlyTest.call_ai
  end

  class AiQueueJob < ApplicationJob
    queue_as { Ai::Routes.queue_for(:detect_merchants) }

    def perform = AiCapsuleOnlyTest.call_ai
  end

  def self.call_ai
    transactions = [ { id: "t1", description: "AMZN", merchant: nil } ]
    AiTestGeneration.new(transactions:, family: Family.first).call(batches: 1)
  end

  class WebController < ApplicationController
    skip_authentication
    skip_before_action :verify_authenticity_token
    skip_before_action :require_onboarding_and_upgrade
    skip_before_action :set_default_chat
    skip_before_action :detect_os

    def index
      AiCapsuleOnlyTest.call_ai
      render plain: "ok"
    end
  end

  tests WebController

  with_routing do |set|
    set.draw { get "index" => "ai_capsule_only_test/web#index" }
  end

  setup do
    use_ai_routes(detect_merchants: %w[gpu/qwen3-8b])
    stub_ai(:detect_merchants) { AiTestGeneration.answer(_1) }
  end

  test "a transport called from a controller raises" do
    assert_equal "ai_background", AiQueueJob.new.queue_name
    assert_raises(Ai::Capsule::Violation) { get :index }
  end

  test "a transport called from a rule job or a default-queue job raises" do
    assert_equal "medium_priority", RuleStyleJob.new.queue_name
    assert_equal "default", DefaultQueueJob.new.queue_name

    assert_raises(Ai::Capsule::Violation) { RuleStyleJob.perform_now }
    assert_raises(Ai::Capsule::Violation) { DefaultQueueJob.perform_now }
  end

  test "the same call passes in an AI job, a capsule or an eval's outside block" do
    assert_nothing_raised { AiQueueJob.perform_now }
    assert_nothing_raised { with_ai_capsule { AiCapsuleOnlyTest.call_ai } }
    assert_nothing_raised { Ai::Capsule.outside { AiCapsuleOnlyTest.call_ai } }
  end
end
