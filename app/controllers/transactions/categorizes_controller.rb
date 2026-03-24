class Transactions::CategorizesController < ApplicationController
  GROUPS_PER_BATCH = 20

  def show
    @position = params[:position].to_i
    groups = Transaction::Grouper.strategy.call(
      Current.family,
      limit: GROUPS_PER_BATCH,
      offset: @position
    )

    if groups.empty?
      redirect_to transactions_path, notice: t(".all_done") and return
    end

    @group      = groups.first
    @categories = Current.family.categories.alphabetically
    @total_uncategorized = Current.family.uncategorized_transaction_count
  end

  def create
    @position    = params[:position].to_i
    entry_ids    = Array.wrap(params[:entry_ids]).reject(&:blank?)
    category     = Current.family.categories.find(params[:category_id])

    entries = Current.family.entries
                     .excluding_split_parents
                     .where(id: entry_ids)

    count = entries.bulk_update!({ category_id: category.id })

    if params[:create_rule] == "1"
      redirect_to new_rule_path(
        resource_type: "transaction",
        name:          params[:grouping_key],
        action_type:   "set_transaction_category",
        action_value:  category.id,
        return_to:     transactions_categorize_path(position: @position)
      )
    else
      redirect_to transactions_categorize_path(position: @position),
        notice: t(".categorized", count: count)
    end
  end
end
