class Transactions::CategorizesController < ApplicationController
  def show
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Transactions", transactions_path ],
      [ "Categorize", nil ]
    ]
    @position = params[:position].to_i
    groups = Transaction::Grouper.strategy.call(
      Current.accessible_entries,
      limit: 1,
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
    entries  = Current.accessible_entries.excluding_split_parents.where(id: entry_ids)
    count    = entries.bulk_update!({ category_id: category.id })

    if params[:create_rule] == "1"
      Rule.create_from_grouping!(
        Current.family,
        params[:grouping_key],
        category,
        transaction_type: params[:transaction_type]
      )
    end

    respond_to do |format|
      format.turbo_stream do
        if remaining_ids.empty?
          render turbo_stream: turbo_stream.action(:redirect, transactions_categorize_path(position: @position))
        else
          @categories = Current.family.categories.alphabetically
          remaining_entries = Current.accessible_entries.excluding_split_parents.where(id: remaining_ids).to_a
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

  def preview_rule
    filter           = params[:filter].to_s.strip
    transaction_type = params[:transaction_type].presence
    entries          = filter.present? ? Entry.uncategorized_matching(Current.family, filter, transaction_type) : []
    @categories      = Current.family.categories.alphabetically

    render turbo_stream: [
      turbo_stream.replace("categorize_group_title",
        partial: "transactions/categorizes/group_title",
        locals: { display_name: filter.presence || "…", color: "#737373", transaction_type: transaction_type }),
      turbo_stream.replace("categorize_group_summary",
        partial: "transactions/categorizes/group_summary",
        locals: { entries: entries }),
      turbo_stream.replace("categorize_transaction_list",
        partial: "transactions/categorizes/transaction_list",
        locals: { entries: entries, categories: @categories })
    ]
  end

  def assign_entry
    entry         = Current.accessible_entries.excluding_split_parents.find(params[:entry_id])
    category      = Current.family.categories.find(params[:category_id])
    position      = params[:position].to_i
    all_entry_ids = Array.wrap(params[:all_entry_ids]).reject(&:blank?)
    remaining_ids = all_entry_ids - [ entry.id.to_s ]

    Entry.where(id: entry.id).bulk_update!({ category_id: category.id })

    streams = [ turbo_stream.remove("categorize_entry_#{entry.id}") ]
    if remaining_ids.empty?
      streams << turbo_stream.action(:redirect, transactions_categorize_path(position: position))
    else
      remaining_entries = Current.accessible_entries.excluding_split_parents.where(id: remaining_ids).to_a
      streams << turbo_stream.replace("categorize_remaining",
        partial: "transactions/categorizes/remaining_count",
        locals: { total_uncategorized: Current.family.uncategorized_transaction_count })
      streams << turbo_stream.replace("categorize_group_summary",
        partial: "transactions/categorizes/group_summary",
        locals: { entries: remaining_entries })
    end
    render turbo_stream: streams
  end
end
