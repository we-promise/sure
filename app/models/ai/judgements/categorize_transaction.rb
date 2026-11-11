# Categorizes each transaction with a decision model: one Choice question over the family's
# categories, one request per transaction.
class Ai::Judgements::CategorizeTransaction < Ai::Judgement
  feature :categorize

  # A Choice always returns one of its options, so without an explicit opt-out the model would
  # have to guess on a transaction that fits nothing. It comes back as no category.
  UNCATEGORIZED = "__uncategorized__".freeze
  INSTRUCTIONS = "Which spending category best fits this bank transaction? " \
                 "Pick `#{UNCATEGORIZED}` only if no category is a reasonable fit.".freeze
  # Jev's documented limit on a Choice's options, the opt-out included.
  MAX_OPTIONS = 255

  # The same arguments as Ai::Generations::CategorizeTransactions.
  def initialize(transactions:, categories:, family:)
    super(family:)
    @transactions, @categories = transactions, categories
  end

  def questions = { category: { type: :choice, instructions: INSTRUCTIONS, options: } }

  def states = @transactions.to_h { [ _1[:id].to_s, state_for(_1) ] }

  # Each answered transaction's category name (nil for the opt-out), the confidence clamped to
  # 0..1 (the threshold it's compared with is, and an out-of-range value would clear every
  # threshold), and the full distribution. A transaction whose answer was malformed is left out.
  def value_from(answers)
    categorizations = @transactions.filter_map do |transaction|
      choice = answers[transaction[:id].to_s]&.dig(:category)
      next unless choice

      { transaction_id: transaction[:id], category_name: (choice.choice unless choice.choice == UNCATEGORIZED),
        confidence: choice.confidence.to_f.clamp(0.0, 1.0), probabilities: choice.probabilities }
    end
    { categorizations: }
  end

  private
    # Categories carry no description, so the hint comes from the hierarchy; nil means the name
    # speaks for itself.
    def options
      if @categories.size >= MAX_OPTIONS
        raise Ai::Error::Refused, "too many categories for one Choice question: at most #{MAX_OPTIONS - 1} plus the opt-out"
      end

      by_id = @categories.index_by { _1[:id].to_s }
      @categories.each_with_object({}) do |category, options|
        parent = by_id[category[:parent_id].to_s]
        options[category[:name].to_s] = parent ? "Subcategory of #{parent[:name]}" : nil
      end.merge(UNCATEGORIZED => "No listed category is a reasonable fit")
    end

    # RubyLLM's judge takes only JSON values, and an entry's amount is a BigDecimal.
    def state_for(transaction)
      transaction.slice(:description, :classification, :merchant, :hint).merge(amount: transaction[:amount]&.to_f).compact
    end
end
