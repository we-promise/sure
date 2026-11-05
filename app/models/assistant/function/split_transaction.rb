# frozen_string_literal: true

class Assistant::Function::SplitTransaction < Assistant::Function
  include Assistant::Function::SplitSupport

  MIN_SPLITS = 2
  MAX_SPLITS = 20
  # entries.amount is decimal(19,4); rounding up front keeps children that sum
  # to the parent as sent from summing to something else once stored.
  AMOUNT_SCALE = 4
  AMOUNT_LIMIT = BigDecimal(10)**15

  class << self
    def name
      "split_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Splits one transaction into 2-20 parts that sum to it, as the split
        editor in the app does. Use it when one payment covers several things,
        e.g. a supermarket shop that was half groceries and half household, or
        a rent payment where half is a flatmate's share.

        Each part becomes its own transaction with its own name, amount,
        category, merchant and tags. A part can be excluded from budgets and
        reports (e.g. someone else's share). The original stays in the ledger
        but is excluded, so only the parts count.

        Amounts use the same sign as the original transaction's amount from
        get_transactions, and the parts must add up to it exactly.

        Passing the id of a part works on the whole split. A transaction that is
        already split is only re-split when replace_existing is true; the parts
        are then replaced, so send the complete set you want. Transfers,
        pending and excluded transactions can't be split. Undo with
        unsplit_transaction.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id", "splits" ],
      properties: {
        id: {
          type: "string",
          description: "Transaction ID from get_transactions"
        },
        splits: {
          type: "array",
          minItems: MIN_SPLITS,
          maxItems: MAX_SPLITS,
          description: "The parts. Their amounts must sum exactly to the transaction's amount.",
          items: {
            type: "object",
            additionalProperties: false,
            required: [ "amount" ],
            properties: {
              name: { type: "string", description: "Name of this part. Defaults to the transaction's name." },
              amount: { type: "string", description: "Amount of this part, as a decimal string with the original's sign, e.g. \"295.00\"." },
              category_id: { type: [ "string", "null" ], description: "Category ID from get_categories." },
              merchant_id: { type: [ "string", "null" ], description: "Merchant ID from get_merchants. Defaults to the transaction's merchant." },
              tag_ids: { type: "array", items: { type: "string" }, description: "Tag IDs from get_tags." },
              excluded: { type: "boolean", description: "Exclude this part from budgets and reports. Defaults to false." }
            }
          }
        },
        replace_existing: {
          type: "boolean",
          description: "Replace the parts of an already split transaction. Defaults to false."
        }
      }
    )
  end

  def call(params = {})
    found = find_split_transaction(params["id"])
    return error("not_found", "Transaction with id '#{params["id"]}' not found.") unless found

    transaction, entry = resolve_split_parent(found)
    return error("not_authorized", "You do not have permission to split this transaction.") unless permitted_to_split?(entry.account)

    replacing = entry.split_parent?
    if replacing && params["replace_existing"] != true
      return error("already_split", "Transaction is already split. Pass replace_existing: true with the full set of parts to replace them.")
    end
    if !replacing && !transaction.splittable?
      return error("not_splittable", not_splittable_reason(transaction, entry))
    end

    splits = build_splits(params["splits"], entry)
    return splits if splits.is_a?(Hash)

    done = replacing ? entry.resplit!(splits) : entry.split_once!(splits)
    unless done
      entry.reload
      transaction.reload
      return error("not_splittable", not_splittable_reason(transaction, entry))
    end

    entry.sync_account_later

    {
      success: true,
      transaction: serialize_split(entry.reload),
      message: "Transaction '#{entry.name}' #{replacing ? "re-split" : "split"} into #{splits.size} parts."
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.presence&.join("; ") || e.message)
  end

  private
    def build_splits(raw, entry)
      unless raw.is_a?(Array) && raw.size.between?(MIN_SPLITS, MAX_SPLITS)
        return error("invalid_splits", "splits must be an array of #{MIN_SPLITS} to #{MAX_SPLITS} parts.")
      end
      return error("invalid_splits", "Each split must be an object.") unless raw.all? { |s| s.is_a?(Hash) }

      splits = raw.each_with_index.map do |s, index|
        position = index + 1

        amount = parse_amount(s["amount"])
        return error("invalid_amount", "Split #{position} needs a numeric amount.") unless amount

        %w[category_id merchant_id].each do |key|
          next if s[key].nil? || s[key].is_a?(String)

          return error("invalid_reference", "Split #{position}: #{key} must be an id.")
        end
        unless s["tag_ids"].nil? || (s["tag_ids"].is_a?(Array) && s["tag_ids"].all?(String))
          return error("invalid_reference", "Split #{position}: tag_ids must be an array of tag ids.")
        end

        references = { category_id: s["category_id"], merchant_id: s["merchant_id"], tag_ids: s["tag_ids"] }
        kind, id = split_references.unknown(**references).first
        return error("invalid_#{kind}", "Split #{position}: unknown #{kind} '#{id}'.") if kind

        name = s["name"].to_s.strip.presence || entry.name
        return error("invalid_name", "Split #{position}: name must be at most 255 characters.") if name.length > 255

        {
          name: name,
          amount: amount,
          excluded: s["excluded"] == true,
          **split_references.scope(**references)
        }
      end

      total = splits.sum { |s| s[:amount] }
      unless total == entry.amount
        return error("amounts_do_not_sum", "Split amounts must sum to #{entry.amount.to_s("F")} (got #{total.to_s("F")}).")
      end

      splits
    end

    def parse_amount(value)
      return nil if value.nil? || value.is_a?(Array) || value.is_a?(Hash) || value == true || value == false

      amount = BigDecimal(value.to_s)
      return nil unless amount.finite?

      amount = amount.round(AMOUNT_SCALE)
      amount.abs < AMOUNT_LIMIT ? amount : nil
    rescue ArgumentError, TypeError
      nil
    end
end
