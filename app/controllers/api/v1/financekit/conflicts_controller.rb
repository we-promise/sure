class Api::V1::Financekit::ConflictsController < Api::V1::Financekit::BaseController
  def index
    conflicts = connection.financekit_conflicts.open.order(created_at: :desc)
      .offset((safe_page_param - 1) * safe_per_page_param).limit(safe_per_page_param)
    render_json({ conflicts: conflicts.map { |conflict| conflict_data(conflict) } })
  end

  def update
    conflict = connection.financekit_conflicts.find(params[:id])
    conflict.resolve!(user: current_resource_owner, resolution: input.fetch("resolution"))
    render_json(conflict_data(conflict))
  end

  private

    def conflict_data(conflict)
      conflict.as_json(only: %i[id kind status details resolution resolved_at created_at],
        methods: %i[financekit_account_lineage_id financekit_transaction_id])
    end
end
