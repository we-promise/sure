class Eval::Result < ApplicationRecord
  self.table_name = "eval_results"

  belongs_to :run, class_name: "Eval::Run", foreign_key: :eval_run_id
  belongs_to :sample, class_name: "Eval::Sample", foreign_key: :eval_sample_id

  validates :actual_output, presence: true
  validates :correct, inclusion: { in: [ true, false ] }

  scope :correct, -> { where(correct: true) }
  scope :incorrect, -> { where(correct: false) }
  scope :with_nulls_returned, -> { where(null_returned: true) }
  scope :with_nulls_expected, -> { where(null_expected: true) }
  scope :exact_matches, -> { where(exact_match: true) }
  scope :hierarchical_matches, -> { where(hierarchical_match: true) }

  # Get actual category (for categorization results)
  def actual_category_name
    actual_output.dig("category_name") || actual_output["category_name"]
  end

  # Get actual merchant info (for merchant detection results)
  def actual_business_name
    actual_output.dig("business_name") || actual_output["business_name"]
  end

  def actual_business_url
    actual_output.dig("business_url") || actual_output["business_url"]
  end

  # Get actual functions called (for chat results)
  def actual_functions
    actual_output.dig("functions") || actual_output["functions"] || []
  end

  # Get actual response text (for chat results)
  def actual_response_text
    actual_output.dig("response_text") || actual_output["response_text"]
  end

  # Summary for display
  def summary
    {
      sample_id: sample_id,
      correct: correct,
      exact_match: exact_match,
      expected: sample.expected_output,
      actual: actual_output,
      latency_ms: latency_ms,
      cost: cost&.to_f
    }
  end

  # Detailed comparison with expected
  def detailed_comparison
    {
      sample_difficulty: sample.difficulty,
      sample_tags: sample.tags,
      input: sample.input_data,
      expected: sample.expected_output,
      actual: actual_output,
      correct: correct,
      exact_match: exact_match,
      hierarchical_match: hierarchical_match,
      null_expected: null_expected,
      null_returned: null_returned,
      fuzzy_score: fuzzy_score
    }
  end
end
