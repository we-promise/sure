class Eval::Sample < ApplicationRecord
  self.table_name = "eval_samples"

  belongs_to :dataset, class_name: "Eval::Dataset", foreign_key: :eval_dataset_id
  has_many :results, class_name: "Eval::Result", foreign_key: :eval_sample_id, dependent: :destroy

  validates :input_data, :expected_output, presence: true
  validates :difficulty, inclusion: { in: %w[easy medium hard manual edge_case] }

  scope :easy, -> { where(difficulty: "easy") }
  scope :medium, -> { where(difficulty: "medium") }
  scope :hard, -> { where(difficulty: "hard") }
  scope :edge_cases, -> { where(difficulty: "edge_case") }
  scope :with_tag, ->(tag) { where("? = ANY(tags)", tag) }
  scope :with_any_tags, ->(tags) { where("tags && ARRAY[?]::varchar[]", tags) }

  # Convert to format expected by AutoCategorizer
  def to_transaction_input
    input_data.deep_symbolize_keys
  end

  # Get categories from context (for categorization evals)
  def categories_context
    context_data.dig("categories") || []
  end

  # Get merchants from context (for merchant detection evals)
  def merchants_context
    context_data.dig("merchants") || []
  end

  # Get mock data from context (for chat evals)
  def mock_data
    context_data.dig("mock_data") || input_data.dig("mock_data") || {}
  end

  # Get the chat prompt (for chat evals)
  def chat_prompt
    input_data.dig("prompt") || input_data["prompt"]
  end

  # Get expected functions (for chat evals)
  def expected_functions
    expected_output.dig("functions") || expected_output["functions"] || []
  end

  # Get expected response keywords (for chat evals)
  def expected_response_contains
    expected_output.dig("response_contains") || expected_output["response_contains"] || []
  end

  # Get expected category name (for categorization evals)
  def expected_category_name
    expected_output.dig("category_name") || expected_output["category_name"]
  end

  # Get acceptable alternative category names (for categorization evals)
  # These are categories that are also considered correct answers
  def acceptable_alternatives
    expected_output.dig("acceptable_alternatives") || expected_output["acceptable_alternatives"] || []
  end

  # Get all acceptable category names (primary + alternatives)
  def all_acceptable_categories
    [ expected_category_name, *acceptable_alternatives ].compact
  end

  # Get expected merchant info (for merchant detection evals)
  def expected_business_name
    expected_output.dig("business_name") || expected_output["business_name"]
  end

  def expected_business_url
    expected_output.dig("business_url") || expected_output["business_url"]
  end

  # Check if null is expected
  def expects_null?
    case dataset.eval_type
    when "categorization"
      expected_category_name.nil?
    when "merchant_detection"
      expected_business_name.nil? && expected_business_url.nil?
    else
      false
    end
  end
end
