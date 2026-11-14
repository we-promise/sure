# Paycheck Flow Planner backend: the graph, allocation, account, and
# income actions that the Plan flow UI drives (Turbo + JSON). The solver
# is PaycheckFlowPlanner (pure functions, no DB); this controller only
# fetches and edits.
class PlanFlowsController < ApplicationController
  include PreviewGateable
  before_action :require_preview_features!

  # Planning diagram JSON: the whole page state in one payload — the saved
  # state with draft rows merged over it: the selected income's saved edges
  # are replaced by the form's edge rows, and the allocation rows merge
  # per-id over the saved set. No write.
  def graph
    @month = Date.current
    @graph = PaycheckFlowPlanner.plan_graph(family: Current.family, month: @month, draft: graph_draft.presence)
    render json: @graph
  end

  # Allocation dialog save (M2 PR#2b): upsert by (family, source bank, name)
  # — re-saving the same row from the dialog edits it in place instead of
  # duplicating. Invalid rows flash the house alert, no 500.
  def create_allocation
    row = plan_allocation_params
    allocation = Current.family.plan_allocations
                               .find_by(account: row[:account], name: row[:name]) ||
               Current.family.plan_allocations.build
    allocation.assign_attributes(row)

    result = begin
      allocation.save!
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  def update_allocation
    allocation = Current.family.plan_allocations.find(params[:id])
    allocation.assign_attributes(plan_allocation_params)

    result = begin
      allocation.save!
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    if result
      redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  def destroy_allocation
    allocation = Current.family.plan_allocations.find(params[:id])
    allocation.destroy!
    redirect_to flow_plan_path(view: flow_view), notice: t(".saved")
  end

  # "Add Bank Account" modal, part 1: attach existing family accounts to the
  # map by giving them a plan_order (max + 1..).
  def add_accounts
    base = Current.family.accounts.maximum(:plan_order).to_i
    Array(params[:account_ids]).compact.map(&:to_s).each_with_index do |account_id, index|
      account = Current.family.accounts.find_by(id: account_id)
      account&.update!(plan_order: base + index + 1)
    end
    redirect_to flow_plan_path(view: flow_view), notice: t(".accounts_added")
  end

  # "Add Bank Account" modal, part 2: create a manual (no-provider) bank
  # account — name + optional institution — and put it on the map.
  def create_account
    # House pattern: delegated_type :accountable needs the object, not just
    # the type column (the "Accountable must exist" validation).
    account = Current.family.accounts.build(
      name: params.dig(:account, :name).presence,
      institution_name: params.dig(:account, :institution_name).presence,
      balance: 0,
      currency: Current.family.currency,
      accountable: Depository.new
    )
    account.plan_order = Current.family.accounts.maximum(:plan_order).to_i + 1

    if account.save
      redirect_to flow_plan_path(view: flow_view), notice: t(".account_created")
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".account_failed")
    end
  end

  # Center card edits: ownership label (Home/Shared | member) + plan_order.
  # The card's single dropdown submits "shared" or "user:<user_id>" so one
  # control writes both plan_ownership and plan_owner_user_id. M2 PR#2b adds
  # the bank-config fields: plan_role (savings bucket / credit card payoff /
  # loan payoff label), auto_transfer_to_account_id, and the linked-income
  # edges (upserted by income+account, per-edge mode/value — same semantics
  # as the edge editor save: checked rows win, unchecked are removed).
  def update_account
    account = Current.family.accounts.find(params[:account_id])
    ownership = params.dig(:account, :plan_ownership).to_s

    result = begin
      ActiveRecord::Base.transaction do
        if ownership.start_with?("user:") && family_user_ids.include?(ownership.delete_prefix("user:"))
          account.update!(plan_ownership: "user", plan_owner_user_id: ownership.delete_prefix("user:"))
        else
          account.update!(plan_ownership: "shared", plan_owner_user_id: nil)
        end

        order = params.dig(:account, :plan_order).presence
        account.update!(plan_order: order.to_i) if order.present?

        apply_bank_config(account)
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    if result
      redirect_back_to_flow
    else
      redirect_to flow_plan_path(view: flow_view, income: params[:income].presence), alert: t(".save_failed")
    end
  end

  # Income card edit: label the income to a family member (or clear the
  # label back to the account-owner fallback). plan_max_account_links is
  # the income's hard bank-link limit: an explicit blank clears it, an
  # omitted param keeps the existing value.
  def update_income
    income = income_series.find { |series| series.id == params[:income_id] }
    return redirect_to flow_plan_path unless income

    result = begin
      ActiveRecord::Base.transaction do
        user_id = params.dig(:series, :plan_owner_user_id).presence
        if user_id.present? && family_user_ids.include?(user_id)
          income.update!(plan_owner_user_id: user_id)
        else
          income.update!(plan_owner_user_id: nil)
        end

        series_params = params.dig(:series)
        if series_params.respond_to?(:key?) && series_params.key?("plan_max_account_links")
          income.update!(plan_max_account_links: series_params["plan_max_account_links"].presence&.to_i)
        end
      end
      true
    rescue ActiveRecord::RecordInvalid
      false
    end

    if result
      redirect_back_to_flow
    else
      redirect_to flow_plan_path(view: flow_view), alert: t(".save_failed")
    end
  end

  private

    def flow_view
      %w[paycheck monthly].include?(params[:view].to_s) ? params[:view] : "paycheck"
    end

    def family_user_ids
      @family_user_ids ||= Current.family.users.pluck(:id).to_set
    end

    # The declared income series of the family, same scope as the Bills
    # income plan (bills_controller#load_paycheck_plan).
    def income_series
      @income_series ||= Current.family.recurring_transactions
                          .accessible_by(Current.user)
                          .where(bill_type: :income)
                          .where.not(status: %i[suggested ended])
                          .order(:name)
    end

    # Center column: every family account, plan_order first (nulls last),
    # then name. The small select on each card writes plan_order.
    def flow_accounts
      @flow_accounts ||= Current.family.accounts
                              .visible
                              .order(Arel.sql("plan_order IS NULL"), :plan_order, :name)
    end

    def load_selected_income
      return nil unless params[:income].present?

      income_series.find { |series| series.id == params[:income] }
    end

    # The form's edge rows for one income, in center-column order:
    # { account_id => { mode:, value: (major units / 0.0-1.0), sort_index: } }.
    def draft_edges(_income)
      edges = params[:edges]
      rows = edges.respond_to?(:to_unsafe_h) ? edges.to_unsafe_h : {}
      return {} if rows.empty?
      flow_accounts.each_with_index.with_object({}) do |(account, index), draft|
        row = rows[account.id.to_s] || rows[account.id]
        next unless row.is_a?(Hash) && row["enabled"].present?

        mode = row["mode"].to_s
        next unless IncomeAccountAllocation.modes.include?(mode)

        raw = row["value"].to_s.strip
        draft[account.id] =
          case mode
          when "specific"
            { mode: mode, value: raw.presence, sort_index: index }
          when "percent"
            percent = raw.to_d / 100
            { mode: mode, value: percent.positive? && percent <= 1 ? percent : 0, sort_index: index }
          else
            { mode: mode, value: nil, sort_index: index }
          end
      end
    end

    # The plan-graph draft: the selected income's saved edges replaced by
    # the form's edge rows, and the allocation rows merged per-id over the
    # saved set. Only the sets the form actually carries are present — the
    # planner applies each draft key wholesale over the saved inputs.
    def graph_draft
      draft = {}

      income = load_selected_income
      if income && params[:edges].present?
        saved_edges = PaycheckFlowPlanner.edge_rows(Current.family)
        rows = draft_edges(income).map do |account_id, attrs|
          {
            income_id: income.id,
            account_id: account_id,
            mode: attrs[:mode],
            value_cents: attrs[:mode] == "specific" ? (attrs[:value].to_f * 100).round : nil,
            value_percent: attrs[:mode] == "percent" ? attrs[:value] : nil
          }
        end
        draft[:allocations] = saved_edges.reject { |edge| edge[:income_id] == income.id } + rows
      end

      if params[:allocations].present?
        draft[:plan_allocations] = merge_draft_allocation_rows
      end

      draft
    end

    # The form's unsaved allocation rows (params[:allocations], keyed by row
    # id) merged per-id over the saved set: an id in the form edits that
    # saved row, an unknown id is a new unsaved row, and saved rows absent
    # from the form survive untouched.
    def merge_draft_allocation_rows
      form_rows = params[:allocations].to_unsafe_h
      saved = PaycheckFlowPlanner.plan_allocation_rows(Current.family)
      form_ids = form_rows.keys.to_set

      saved.reject { |row| form_ids.include?(row[:id]) } +
        form_rows.map do |row_id, attrs|
          next unless attrs.is_a?(Hash)

          base = saved.find { |row| row[:id] == row_id } ||
                 { id: row_id, value_cents: nil, value_percent: nil, cadence: nil,
                   recurring_transaction_id: nil, auto_transfer: false }
          mode = attrs["mode"].to_s
          base.merge(
            account_id: attrs["account_id"],
            name: attrs["name"].presence,
            kind: attrs["kind"],
            mode: mode,
            value_cents: %w[specific required].include?(mode) ? parse_value_cents(attrs["value"]) : nil,
            value_percent: mode == "percent" ? parse_value_percent(attrs["value_percent"]) : nil,
            cadence: attrs["cadence"].presence,
            recurring_transaction_id: attrs["recurring_transaction_id"].presence,
            auto_transfer: attrs["auto_transfer"].present?
          )
        end.compact
    end

    # The allocation dialog's row, planner-value shaped (value in major
    # units, percent in 0-100 — same conventions as the edge editor).
    def plan_allocation_params
      a = params[:plan_allocation]
      mode = a[:mode].to_s

      {
        account: Current.family.accounts.find_by(id: a[:account_id]),
        name: a[:name].presence,
        kind: a[:kind],
        mode: mode,
        value_cents: %w[specific required].include?(mode) ? parse_value_cents(a[:value]) : nil,
        value_percent: mode == "percent" ? parse_value_percent(a[:value_percent]) : nil,
        cadence: a[:cadence].presence,
        recurring_transaction_id: a[:recurring_transaction_id].presence,
        auto_transfer: a[:auto_transfer].present?
      }
    end

    # Dialog value (major units, e.g. "300.00") in cents; blank or zero -> nil.
    def parse_value_cents(value)
      return nil if value.blank?

      cents = value.to_s.to_d * 100
      cents.zero? ? nil : cents
    end

    # Dialog percent (0-100, e.g. "10" = 10%) as a 0-1 fraction; blank or
    # zero -> nil.
    def parse_value_percent(value)
      return nil if value.blank?

      fraction = value.to_s.to_d / 100
      fraction.zero? ? nil : fraction
    end

    # Bank-config fields from the center card dialog (M2 PR#2b): plan_role,
    # auto_transfer_to_account_id, and the linked-income edges. Absent keys
    # are left alone, so the old two-field card form keeps working.
    def apply_bank_config(account)
      account_params = params.dig(:account)
      return unless account_params.respond_to?(:key?)

      if account_params.key?("plan_role")
        account.update!(plan_role: account_params["plan_role"].presence)
      end
      if account_params.key?("auto_transfer_to_account_id")
        account.update!(auto_transfer_to_account_id: account_params["auto_transfer_to_account_id"].presence)
      end
      save_bank_links(account) if params[:links].respond_to?(:to_unsafe_h) && params[:links].to_unsafe_h.any?
    end

    # Linked-income edges from the bank config dialog: the dialog lists the
    # family's editable incomes, so the links param is complete over them —
    # checked rows upsert the edge (per-edge mode/value), unchecked existing
    # rows for those incomes are removed. Incomes the user cannot edit keep
    # their edges.
    def save_bank_links(account)
      links = params[:links].to_unsafe_h
      existing = Current.family.income_account_allocations
                               .where(account_id: account.id)
                               .index_by(&:income_series_id)

      links.each do |income_id, row|
        series = income_series.find { |s| s.id == income_id }
        next unless series

        row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
        if row["enabled"].present?
          mode = row["mode"].to_s
          next unless IncomeAccountAllocation.modes.include?(mode)

          value = case mode
          when "specific"
            row["value"].to_s.strip.presence
          when "percent"
            percent = row["value"].to_s.strip.to_d / 100
            (percent.positive? && percent <= 1) ? percent : 0
          else
            nil
          end

          edge = existing.delete(series.id)
          if edge
            edge.update!(mode: mode, value: value)
          else
            IncomeAccountAllocation.create!(
              family: Current.family, income_series: series, account: account,
              mode: mode, value: value
            )
          end
        else
          existing.delete(series.id)&.destroy!
        end
      end
      # Remove only the edges of incomes the user can edit; edges on
      # non-editable incomes survive the dialog.
      editable_ids = income_series.map(&:id).to_set
      existing.each_value { |allocation| allocation.destroy! if editable_ids.include?(allocation.income_series_id) }
    end

    def redirect_back_to_flow
      redirect_to flow_plan_path(view: flow_view, income: params[:income].presence)
    end
end
