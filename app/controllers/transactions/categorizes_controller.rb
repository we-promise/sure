class Transactions::CategorizesController < ApplicationController
  GROUPS_PER_BATCH = 20

  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Transactions", transactions_path ],
      [ "Categorize", nil ]
    ]
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
    @position     = params[:position].to_i
    entry_ids     = Array.wrap(params[:entry_ids]).reject(&:blank?)
    all_entry_ids = Array.wrap(params[:all_entry_ids]).reject(&:blank?)
    remaining_ids = all_entry_ids - entry_ids

    category = Current.family.categories.find(params[:category_id])
    entries  = Current.family.entries.excluding_split_parents.where(id: entry_ids)
    count    = entries.bulk_update!({ category_id: category.id })
    create_rule_for_group(params[:grouping_key], category) if params[:create_rule] == "1"

    respond_to do |format|
      format.turbo_stream do
        if remaining_ids.empty?
          render turbo_stream: turbo_stream.action(:redirect, transactions_categorize_path(position: @position))
        else
          @categories = Current.family.categories.alphabetically
          remaining_entries = Current.family.entries.excluding_split_parents.where(id: remaining_ids).to_a
          streams = entry_ids.map { |id| turbo_stream.remove("categorize_entry_#{id}") }
          remaining_entries.each do |entry|
            streams << turbo_stream.replace(
              "categorize_entry_#{entry.id}",
              partial: "transactions/categorizes/entry_row",
              locals: { entry: entry, categories: @categories }
            )
          end
          streams << turbo_stream.replace("categorize_remaining",
            partial: "transactions/categorizes/remaining_count",
            locals: { total_uncategorized: Current.family.uncategorized_transaction_count })
          streams << turbo_stream.replace("categorize_group_summary",
            partial: "transactions/categorizes/group_summary",
            locals: { entries: remaining_entries })
          render turbo_stream: streams
        end
      end
      format.html { redirect_to transactions_categorize_path(position: @position), notice: t(".categorized", count: count) }
    end
  end

  def assign_entry
    entry         = Current.family.entries.excluding_split_parents.find(params[:entry_id])
    category      = Current.family.categories.find(params[:category_id])
    position      = params[:position].to_i
    all_entry_ids = Array.wrap(params[:all_entry_ids]).reject(&:blank?)
    remaining_ids = all_entry_ids - [ entry.id.to_s ]

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    streams = [ turbo_stream.remove("categorize_entry_#{entry.id}") ]
    if remaining_ids.empty?
      streams << turbo_stream.action(:redirect, transactions_categorize_path(position: position))
    else
      remaining_entries = Current.family.entries.excluding_split_parents.where(id: remaining_ids).to_a
      streams << turbo_stream.replace("categorize_remaining",
        partial: "transactions/categorizes/remaining_count",
        locals: { total_uncategorized: Current.family.uncategorized_transaction_count })
      streams << turbo_stream.replace("categorize_group_summary",
        partial: "transactions/categorizes/group_summary",
        locals: { entries: remaining_entries })
    end
    render turbo_stream: streams
  end

  private

    def create_rule_for_group(grouping_key, category)
      rule = Current.family.rules.build(
        name: grouping_key,
        resource_type: "transaction",
        active: true
      )
      rule.conditions.build(condition_type: "transaction_name", operator: "like", value: grouping_key)
      rule.actions.build(action_type: "set_transaction_category", value: category.id.to_s)
      rule.save!
    rescue ActiveRecord::RecordInvalid
      # Rule already exists or is invalid — skip silently
    end
end
