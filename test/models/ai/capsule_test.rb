require "test_helper"

class Ai::CapsuleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class CapsuleProbeJob < ApplicationJob
    def perform = self.class.seen << Ai::Capsule.inside?

    def self.seen = @seen ||= []
  end

  setup { CapsuleProbeJob.seen.clear }

  test "a job on an AI queue runs inside the capsule; a job on any other queue doesn't" do
    Ai::Capsule::QUEUES.each { CapsuleProbeJob.set(queue: _1).perform_now }
    %w[high_priority low_priority default].each { CapsuleProbeJob.set(queue: _1).perform_now }

    assert_equal [ true ] * Ai::Capsule::QUEUES.size + [ false ] * 3, CapsuleProbeJob.seen
    assert_not Ai::Capsule.inside?
  end

  test "the test adapter runs the same hook" do
    perform_enqueued_jobs { CapsuleProbeJob.set(queue: Ai::Routes.queue_for(:categorize)).perform_later }

    assert_equal [ true ], CapsuleProbeJob.seen
  end

  test "the capsule's queues are the AI lanes' queues" do
    assert_equal Ai::Routes::QUEUES.values.uniq.sort, Ai::Capsule::QUEUES.sort
  end

  test "check! raises outside the capsule and passes inside it or inside outside" do
    assert_raises(Ai::Capsule::Violation) { Ai::Capsule.check! }
    assert_nil with_ai_capsule { Ai::Capsule.check! }
    assert_nil Ai::Capsule.outside { Ai::Capsule.check! }
    assert_not Ai::Capsule.outside { Ai::Capsule.inside? }
  end

  test "check! does nothing in production" do
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new("production"))

    assert_nil Ai::Capsule.check!
  end

  test "the mark is restored after the block, even when it raises" do
    assert_raises(RuntimeError) { with_ai_capsule { raise "boom" } }
    assert_not Ai::Capsule.inside?

    Ai::Capsule.outside { with_ai_capsule { assert Ai::Capsule.inside? }; assert_nil Ai::Capsule.check! }
    assert_raises(Ai::Capsule::Violation) { Ai::Capsule.check! }
  end

  test "a violation is a bug, not a model failure the plumbing would rescue" do
    assert_not Ai::Capsule::Violation < Ai::Error::Base
  end
end

class Ai::CapsuleClassLevelTest < ActiveSupport::TestCase
  ai_capsule!

  test "ai_capsule! puts every test in the class inside" do
    assert Ai::Capsule.inside?
    assert_nil Ai::Capsule.check!
  end
end
