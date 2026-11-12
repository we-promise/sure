class MerchantsController < ApplicationController
  def show
    @merchant = find_merchant

    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.merchants"), family_merchants_path ],
      [ @merchant.name, nil ]
    ]

    @accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
    @search = merchant_search
    @expense_totals = merchant_search(types: [ "expense" ]).totals
    @average_expense_money = @expense_totals.expense_money / @expense_totals.count if @expense_totals.count.positive?
    @first_date, @last_date = @search.transactions_scope.pick(Arel.sql("MIN(entries.date)"), Arel.sql("MAX(entries.date)"))

    @pagy, @transactions = pagy(
      @search.transactions_scope.reverse_chronological.includes(
        { entry: :account }, :category, :merchant, :tags,
        { transfer_as_outflow: { inflow_transaction: { entry: :account } } },
        { transfer_as_inflow: { inflow_transaction: { entry: :account }, outflow_transaction: [ :category, { entry: :account } ] } }
      ),
      limit: safe_per_page(50)
    )
    Transaction::ActivitySecurityPreloader.new(@transactions).preload

    @split_parents = load_split_parents
    @split_parent_entry_ids = Entry.split_parent_ids_among(@transactions.map { |t| t.entry.id })
    @projected_recurring = []
    @q = {}
  end

  private
    def find_merchant
      Current.family.available_merchants_for(Current.user).find(params[:id])
    end

    def merchant_search(**filters)
      Transaction::Search.new(
        Current.family,
        filters: { merchants: [ @merchant.name ], **filters },
        accessible_account_ids: @accessible_account_ids
      )
    end

    def load_split_parents
      return {} unless Current.user.show_split_grouped?

      parent_ids = @transactions.filter_map { |t| t.entry.parent_entry_id }.uniq
      return {} if parent_ids.empty?

      Entry.where(id: parent_ids).includes(:account, entryable: [ :category, :merchant ]).index_by(&:id)
    end
end
