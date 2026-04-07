class Transactions::CategorizesController < ApplicationController
  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.transactions"), transactions_path ],
      [ t("breadcrumbs.categorize"), nil ]
    ]
    @position = [ params[:position].to_i, 0 ].max
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
    @total_uncategorized = Entry.uncategorized_count(Current.accessible_entries)
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
      rule = Rule.create_from_grouping(
        Current.family,
        params[:grouping_key],
        category,
        transaction_type: params[:transaction_type]
      )
      flash[:alert] = t(".rule_creation_failed") if rule.nil?
    end

    respond_to do |format|
      format.turbo_stream do
        remaining_entries = uncategorized_entries_for(remaining_ids)
        remaining_ids     = remaining_entries.map { |e| e.id.to_s }

        if remaining_ids.empty?
          render turbo_stream: turbo_stream.action(:redirect, transactions_categorize_path(position: @position))
        else
          @categories = Current.family.categories.alphabetically
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
            locals: { total_uncategorized: Entry.uncategorized_count(Current.accessible_entries) })
          streams << turbo_stream.replace("categorize_group_summary",
            partial: "transactions/categorizes/group_summary",
            locals: { entries: remaining_entries })
          streams.concat(flash_notification_stream_items)
          render turbo_stream: streams
        end
      end
      format.html { redirect_to transactions_categorize_path(position: @position), notice: t(".categorized", count: count) }
    end
  end

  def preview_rule
    filter           = params[:filter].to_s.strip
    transaction_type = params[:transaction_type].presence
    entries          = filter.present? ? Entry.uncategorized_matching(Current.accessible_entries, filter, transaction_type) : []
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

    remaining_entries = uncategorized_entries_for(remaining_ids)
    remaining_ids     = remaining_entries.map { |e| e.id.to_s }

    streams = [ turbo_stream.remove("categorize_entry_#{entry.id}") ]
    if remaining_ids.empty?
      streams << turbo_stream.action(:redirect, transactions_categorize_path(position: position))
    else
      streams << turbo_stream.replace("categorize_remaining",
        partial: "transactions/categorizes/remaining_count",
        locals: { total_uncategorized: Entry.uncategorized_count(Current.accessible_entries) })
      streams << turbo_stream.replace("categorize_group_summary",
        partial: "transactions/categorizes/group_summary",
        locals: { entries: remaining_entries })
    end
    render turbo_stream: streams
  end

  private

    def uncategorized_entries_for(ids)
      return [] if ids.blank?
      Current.accessible_entries
        .excluding_split_parents
        .where(id: ids)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(transactions: { category_id: nil })
        .to_a
    end
end
