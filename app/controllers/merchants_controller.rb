class MerchantsController < ApplicationController
  include FilterClearable

  def show
    @merchant = find_merchant
    @q = search_params

    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.merchants"), family_merchants_path ],
      [ @merchant.name, nil ]
    ]

    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
    @search = merchant_search
    if @q[:types].blank? || @q[:types].include?("expense")
      @expense_totals = merchant_search(types: [ "expense" ]).totals
      @average_expense_money = @expense_totals.expense_money / @expense_totals.count if @expense_totals.count.positive?
    end
    @first_date, @last_date = @search.transactions_scope.pick(Arel.sql("MIN(entries.date)"), Arel.sql("MAX(entries.date)"))

    @pagy, @transactions = pagy(
      @search.transactions_scope.reverse_chronological.includes(
        { entry: :account }, :category, :merchant, :tags,
        { transfer_as_outflow: { inflow_transaction: [ :category, { entry: :account } ] } },
        { transfer_as_inflow: { inflow_transaction: { entry: :account }, outflow_transaction: [ :category, { entry: :account } ] } }
      ),
      limit: safe_per_page(50)
    )
    Transaction::ActivitySecurityPreloader.new(@transactions).preload

    @split_parents = load_split_parents
    @split_parent_entry_ids = Entry.split_parent_ids_among(@transactions.map { |t| t.entry.id })
    @projected_recurring = []
  end

  def clear_filter
    redirect_to merchant_path(find_merchant, q: without_cleared_filter(search_params), page: params[:page], per_page: params[:per_page])
  end

  private
    def find_merchant
      Current.family.available_merchants_for(Current.user).find(params[:id])
    end

    def merchant_search(**filters)
      Transaction::Search.new(
        Current.family,
        filters: { **@q.symbolize_keys, merchants: [ @merchant.name ], **filters },
        accessible_account_ids: @accessible_account_ids
      )
    end

    def search_params
      q = params.fetch(:q, {}).permit(
        :search, :start_date, :end_date, :amount, :amount_operator,
        accounts: [], categories: [], tags: [], types: [], status: []
      ).to_h.compact_blank
      q.delete("amount_operator") unless q["amount"].present?
      q
    end

    def load_split_parents
      return {} unless Current.user.show_split_grouped?

      parent_ids = @transactions.filter_map { |t| t.entry.parent_entry_id }.uniq
      return {} if parent_ids.empty?

      Entry.where(id: parent_ids).includes(:account, entryable: [ :category, :merchant ]).index_by(&:id)
    end
end
