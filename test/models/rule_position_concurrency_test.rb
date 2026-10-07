require "test_helper"
require "concurrent"

# Rules created for the same family at the same time must still get distinct
# run positions. Real threads on real connections, so this needs real commits.
class RulePositionConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  # Stays below the test database pool size (the test thread holds one).
  WRITERS = 3

  setup do
    @family = Family.create!(name: "Rule Position Race", currency: "USD")
  end

  teardown do
    Rule.where(family_id: @family.id).destroy_all
    @family.destroy
  end

  test "concurrently created rules get distinct positions" do
    latch = Concurrent::CountDownLatch.new(WRITERS)

    WRITERS.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          latch.count_down
          latch.wait(5)
          @family.rules.create!(
            resource_type: "transaction",
            actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
          )
        end
      end
    end.each(&:join)

    positions = Rule.where(family_id: @family.id).pluck(:position)
    assert_equal WRITERS, positions.size
    assert_equal (1..WRITERS).to_a, positions.sort
  end
end
