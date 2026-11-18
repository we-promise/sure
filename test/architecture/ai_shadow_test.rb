require "test_helper"

# Section 17's shadow checks: every class that declares `shadow` declares how its values compare
# and has a `shadow_<feature>` row, every shadow row has a class that runs it, and shadow results
# reach only ComparisonSubscriber.
class AiShadowTest < ActiveSupport::TestCase
  APP = Rails.root.join("app")

  def generations
    Rails.root.glob("app/models/ai/generations/*.rb").map { "Ai::Generations::#{_1.basename(".rb").to_s.camelize}".constantize }
  end

  test "every shadow declares a comparison, a subject and a shadow_ row" do
    shadowed = generations.select(&:shadow_compare)

    assert_not_empty shadowed
    shadowed.each do |generation|
      assert generation.shadow_compare.respond_to?(:call), "#{generation} compare: must be callable"
      assert generation.shadow_subject.safe_constantize, "#{generation} subject: names no class"
      assert_includes Ai::Routes::MATRIX.keys, Ai::Shadow.feature_for(generation.feature_key), "#{generation} has no shadow_ row"
      assert generation.public_method_defined?(:arguments), "#{generation} must define #arguments for the shadow job"
    end
  end

  test "every shadow_ row has a generation that declares shadow" do
    shadow_rows = Ai::Routes::MATRIX.select { |_, spec| spec[:shadow_of] }.keys
    declared = generations.select(&:shadow_compare).map { Ai::Shadow.feature_for(_1.feature_key) }

    assert_empty shadow_rows - declared, "shadow rows nothing runs"
  end

  test "only ComparisonSubscriber writes Ai::Comparison, and only the shadow job emits its event" do
    writers = APP.glob("**/*.rb").select { _1.read.match?(/Ai::Comparison\.(create|insert|upsert|new)/) }
    emitters = APP.glob("**/*.{rb,erb}").select { _1.read.include?("Ai::Shadow::EVENT") }

    assert_equal [ "models/ai/instrumentation/comparison_subscriber.rb" ], writers.map { _1.relative_path_from(APP).to_s }
    assert_equal %w[jobs/ai/shadow_job.rb models/ai/instrumentation.rb], emitters.map { _1.relative_path_from(APP).to_s }.sort
  end

  test "shadow answers are never written to the item" do
    source = Rails.root.join("app/jobs/ai/shadow_job.rb").read + Rails.root.join("app/models/ai/shadow.rb").read

    assert_no_match(/enrich_attribute|update!|DataEnrichment|lock_attr/, source)
  end
end
