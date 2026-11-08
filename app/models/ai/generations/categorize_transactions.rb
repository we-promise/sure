# Picks a category for each transaction from the family's own, or none. On a `judge` model
# (Jev), Ai::Judgements::CategorizeTransaction answers instead, in the same shape.
class Ai::Generations::CategorizeTransactions < Ai::Generation
  feature :categorize
  prompt "categorize_transactions"
  schema_name "auto_categorize_personal_finance_transactions"
  batch :transactions
  merge :categorizations, by: :transaction_id
  required :transaction_id
  aliases categorizations: %w[results], transaction_id: %w[id txn_id], category_name: %w[category name]
  blank_item { _1[:category_name].nil? }
  judged_by Ai::Judgements::CategorizeTransaction
  # Category ids, not names, so renamed or duplicate categories still compare (section 8.2).
  shadow subject: "Transaction",
         compare: ->(value) { value[:categorizations].to_h { [ _1[:transaction_id].to_s, [ category_id_for(_1[:category_name]), _1[:confidence] ] ] } }

  # Common ways a model names a category the family spells differently.
  NAME_VARIATIONS = [
    [ "gas & fuel", "gas and fuel", "fuel", "gasoline" ], [ "restaurant", "dining", "food" ],
    [ "grocery", "supermarket", "food store" ], [ "streaming services", "streaming service" ],
    [ "ride share", "ride-share", "uber", "lyft" ], [ "coffee shops", "coffee shop", "cafe" ],
    [ "fastfood", "quick service" ], [ "gym & fitness", "fitness", "gym and fitness" ],
    [ "flight", "airline", "airlines", "airfare" ], [ "hotel", "lodging", "accommodation" ]
  ].freeze

  # transactions: [{ id:, amount:, classification:, description:, merchant: }];
  # categories: the family's, [{ id:, name:, is_subcategory:, parent_id: }].
  def initialize(transactions:, categories:, family:)
    super(family:)
    @transactions, @categories = transactions, categories
  end

  def prompt_locals = { transactions: items, categories: @categories }

  def arguments = { transactions: items, categories: @categories }

  # The family's spelling of the category the model named: exact, then ignoring case, then a
  # fuzzy match (today's OpenAI normaliser, now on every protocol). Nil when nothing matches.
  def matchers = { category_name: ->(name) { category_name_for(name.to_s.strip) } }

  def schema
    {
      type: "object",
      properties: {
        categorizations: {
          type: "array",
          description: "An array of auto-categorizations for each transaction",
          items: {
            type: "object",
            properties: {
              transaction_id: { type: "string", description: "The internal ID of the original transaction", enum: items.map { _1[:id].to_s } },
              category_name: { type: %w[string null], description: "The matched category name of the transaction, or null if no match",
                               enum: [ *@categories.map { _1[:name] }, "null", nil ] }
            },
            required: %w[transaction_id category_name],
            additionalProperties: false
          }
        }
      },
      required: %w[categorizations],
      additionalProperties: false
    }
  end

  private
    def category_id_for(name) = name && @categories.find { _1[:name].to_s == name.to_s }&.dig(:id)&.to_s

    def category_name_for(name)
      names = @categories.map { _1[:name].to_s }
      names.find { _1 == name } || names.find { _1.casecmp?(name) } || fuzzy_match(name, names)
    end

    def fuzzy_match(name, names)
      squeezed = name.downcase.gsub(/[^a-z0-9]/, "")
      return if squeezed.empty?

      names.find do |candidate|
        other = candidate.downcase.gsub(/[^a-z0-9]/, "")
        (other.present? && (squeezed.include?(other) || other.include?(squeezed))) ||
          NAME_VARIATIONS.any? { |group| group.include?(name.downcase) && group.include?(candidate.downcase) }
      end
    end
end
