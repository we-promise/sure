class PagesController < ApplicationController
  include Periodable

  skip_authentication only: %i[redis_configuration_error privacy terms]
  before_action :ensure_intro_guest!, only: :intro

  def dashboard
    if Current.user&.ui_layout_intro?
      redirect_to chats_path and return
    end

    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.user.accessible_accounts.visible.with_attached_logo
    @finance_accounts = Current.user.finance_accounts.visible.alphabetically
    @sankey_mode = resolved_sankey_mode
    @selected_account = @sankey_mode == "aggregate" ? @finance_accounts.find_by(id: params[:account_id].presence) : nil

    family_currency = Current.family.currency
    selected_account_ids = @selected_account ? [ @selected_account.id ] : nil

    if @sankey_mode == "split"
      income_statement = Current.family.income_statement(user: Current.user)
      net_totals = income_statement.net_category_totals(period: @period)
      @cashflow_sankey_data = build_split_cashflow_sankey_data(accounts: @finance_accounts, period: @period, currency: family_currency)
    else
      # Use IncomeStatement for all cashflow data (now includes categorized trades)
      income_statement = Current.family.income_statement(user: Current.user, account_ids: selected_account_ids)
      income_totals = income_statement.income_totals(period: @period)
      expense_totals = income_statement.expense_totals(period: @period)
      net_totals = income_statement.net_category_totals(period: @period)
      transfer_flows = @selected_account ?
        build_transfer_flows_for_account(
          account: @selected_account,
          period: @period,
          currency: family_currency,
          accessible_account_ids: @accounts.map(&:id).to_set
        ) : nil

      @cashflow_sankey_data = build_cashflow_sankey_data(net_totals, income_totals, expense_totals, family_currency, transfer_flows: transfer_flows)
    end

    @outflows_data = build_outflows_donut_data(net_totals)

    @dashboard_sections = build_dashboard_sections

    @breadcrumbs = [ [ "Home", root_path ], [ "Dashboard", nil ] ]
  end

  def intro
    @breadcrumbs = [ [ "Home", chats_path ], [ "Intro", nil ] ]
  end

  def update_preferences
    if Current.user.update_dashboard_preferences(preferences_params)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: "Release notes unavailable",
        published_at: Date.current,
        body: "<p>Unable to fetch the latest release notes at this time. Please check back later or visit our <a href='https://github.com/we-promise/sure/releases' target='_blank'>GitHub releases page</a> directly.</p>"
      }
    end

    render layout: "settings"
  end

  def feedback
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  def privacy
    render layout: "blank"
  end

  def terms
    render layout: "blank"
  end

  private
    def preferences_params
      prefs = params.require(:preferences)
      {}.tap do |permitted|
        permitted["collapsed_sections"] = prefs[:collapsed_sections].to_unsafe_h if prefs[:collapsed_sections]
        permitted["section_order"] = prefs[:section_order] if prefs[:section_order]
      end
    end

    def build_dashboard_sections
      all_sections = [
        {
          key: "cashflow_sankey",
          title: "pages.dashboard.cashflow_sankey.title",
          partial: "pages/dashboard/cashflow_sankey",
          locals: {
            sankey_data: @cashflow_sankey_data,
            period: @period,
            finance_accounts: @finance_accounts,
            selected_account_id: @selected_account&.id,
            sankey_mode: @sankey_mode
          },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "outflows_donut",
          title: "pages.dashboard.outflows_donut.title",
          partial: "pages/dashboard/outflows_donut",
          locals: { outflows_data: @outflows_data, period: @period },
          visible: @accounts.any? && @outflows_data[:categories].present?,
          collapsible: true
        },
        {
          key: "investment_summary",
          title: "pages.dashboard.investment_summary.title",
          partial: "pages/dashboard/investment_summary",
          locals: { investment_statement: @investment_statement, period: @period },
          visible: @accounts.any? && @investment_statement.investment_accounts.any?,
          collapsible: true
        },
        {
          key: "net_worth_chart",
          title: "pages.dashboard.net_worth_chart.title",
          partial: "pages/dashboard/net_worth_chart",
          locals: { balance_sheet: @balance_sheet, period: @period },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "balance_sheet",
          title: "pages.dashboard.balance_sheet.title",
          partial: "pages/dashboard/balance_sheet",
          locals: { balance_sheet: @balance_sheet },
          visible: @accounts.any?,
          collapsible: true
        }
      ]

      # Order sections according to user preference
      section_order = Current.user.dashboard_section_order
      ordered_sections = section_order.map do |key|
        all_sections.find { |s| s[:key] == key }
      end.compact

      # Add any new sections that aren't in the saved order (future-proofing)
      all_sections.each do |section|
        ordered_sections << section unless ordered_sections.include?(section)
      end

      ordered_sections
    end

    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_cashflow_sankey_data(net_totals, income_totals, expense_totals, currency, transfer_flows: nil)
      nodes = []
      links = []
      node_indices = {}

      add_node = ->(unique_key, display_name, value, percentage, color) {
        node_indices[unique_key] ||= begin
          nodes << { name: display_name, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
          nodes.size - 1
        end
      }

      total_income = net_totals.total_net_income.to_f.round(2)
      total_expense = net_totals.total_net_expense.to_f.round(2)

      # Central Cash Flow node
      cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income, 100.0, "var(--color-success)")

      # Build netted subcategory data from raw totals
      net_subcategories_by_parent = build_net_subcategories(expense_totals, income_totals)

      # Process net income categories (flow: subcategory -> parent -> cash_flow)
      process_net_category_nodes(
        categories: net_totals.net_income_categories,
        total: total_income,
        prefix: "income",
        net_subcategories_by_parent: net_subcategories_by_parent,
        add_node: add_node,
        links: links,
        cash_flow_idx: cash_flow_idx,
        flow_direction: :inbound
      )

      # Process net expense categories (flow: cash_flow -> parent -> subcategory)
      process_net_category_nodes(
        categories: net_totals.net_expense_categories,
        total: total_expense,
        prefix: "expense",
        net_subcategories_by_parent: net_subcategories_by_parent,
        add_node: add_node,
        links: links,
        cash_flow_idx: cash_flow_idx,
        flow_direction: :outbound
      )

      append_transfer_flows(
        transfer_flows: transfer_flows,
        add_node: add_node,
        links: links,
        cash_flow_idx: cash_flow_idx
      )

      # Surplus/Deficit
      net = (total_income - total_expense).round(2)
      if net.positive?
        percentage = total_income.zero? ? 0 : (net / total_income * 100).round(1)
        idx = add_node.call("surplus_node", "Surplus", net, percentage, "var(--color-success)")
        links << { source: cash_flow_idx, target: idx, value: net, color: "var(--color-success)", percentage: percentage }
      end

      { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency).symbol }
    end

    def append_transfer_flows(transfer_flows:, add_node:, links:, cash_flow_idx:, key_namespace: nil, inbound_label_prefix: nil, outbound_label_prefix: nil)
      return if transfer_flows.blank?

      transfer_color = Category::TRANSFER_COLOR
      inbound_base = transfer_flows[:total_inbound].to_f
      outbound_base = transfer_flows[:total_outbound].to_f
      key_prefix = key_namespace.present? ? "#{key_namespace}_" : ""
      inbound_prefix = inbound_label_prefix.presence || "#{I18n.t("pages.dashboard.cashflow_sankey.from_label")} "
      outbound_prefix = outbound_label_prefix.presence || "#{I18n.t("pages.dashboard.cashflow_sankey.to_label")} "

      transfer_flows[:inbound].each do |flow|
        value = flow[:value].to_f.round(2)
        next if value.zero?

        percentage = inbound_base.zero? ? 0 : (value / inbound_base * 100).round(1)
        idx = add_node.call("#{key_prefix}transfer_in_#{flow[:key]}", "#{inbound_prefix}#{flow[:name]}", value, percentage, transfer_color)
        links << { source: idx, target: cash_flow_idx, value: value, color: transfer_color, percentage: percentage, flow_type: "transfer_in" }
      end

      transfer_flows[:outbound].each do |flow|
        value = flow[:value].to_f.round(2)
        next if value.zero?

        percentage = outbound_base.zero? ? 0 : (value / outbound_base * 100).round(1)
        idx = add_node.call("#{key_prefix}transfer_out_#{flow[:key]}", "#{outbound_prefix}#{flow[:name]}", value, percentage, transfer_color)
        links << { source: cash_flow_idx, target: idx, value: value, color: transfer_color, percentage: percentage, flow_type: "transfer_out" }
      end
    end

    # Nets subcategory expense and income totals, grouped by parent_id.
    # Returns { parent_id => [ { category:, total: net_amount }, ... ] }
    # Only includes subcategories with positive net (same direction as parent).
    def build_net_subcategories(expense_totals, income_totals)
      expense_subs = expense_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      income_subs = income_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      all_sub_ids = (expense_subs.keys + income_subs.keys).uniq
      result = {}

      all_sub_ids.each do |sub_id|
        exp_ct = expense_subs[sub_id]
        inc_ct = income_subs[sub_id]
        exp_total = exp_ct&.total || 0
        inc_total = inc_ct&.total || 0
        net = exp_total - inc_total
        category = exp_ct&.category || inc_ct&.category

        next if net.zero?

        parent_id = category.parent_id
        result[parent_id] ||= []
        result[parent_id] << { category: category, total: net.abs, net_direction: net > 0 ? :expense : :income }
      end

      result
    end

    # Builds sankey nodes/links for net categories with subcategory hierarchy.
    # Subcategories matching the parent's flow direction are shown as children.
    # Subcategories with opposite net direction appear on the OTHER side of the
    # sankey (handled when the other side calls this method).
    #
    # flow_direction: :inbound  (subcategory -> parent -> cash_flow) for income
    #                 :outbound (cash_flow -> parent -> subcategory) for expenses
    def process_net_category_nodes(categories:, total:, prefix:, net_subcategories_by_parent:, add_node:, links:, cash_flow_idx:, flow_direction:, key_namespace: nil)
      matching_direction = flow_direction == :inbound ? :income : :expense
      key_prefix = key_namespace.present? ? "#{key_namespace}_" : ""

      categories.each do |ct|
        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total.zero? ? 0 : (val / total * 100).round(1)
        color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR
        node_key = "#{key_prefix}#{prefix}_#{ct.category.id || ct.category.name}"

        all_subs = ct.category.id ? (net_subcategories_by_parent[ct.category.id] || []) : []
        same_side_subs = all_subs.select { |s| s[:net_direction] == matching_direction }

        # Also check if any subcategory has opposite direction — those will be
        # rendered by the OTHER side's call to this method, linked to cash_flow
        # directly (they appear as independent nodes on the opposite side).
        opposite_subs = all_subs.select { |s| s[:net_direction] != matching_direction }

        if same_side_subs.any?
          parent_idx = add_node.call(node_key, ct.category.name, val, percentage, color)

          if flow_direction == :inbound
            links << { source: parent_idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: parent_idx, value: val, color: color, percentage: percentage }
          end

          same_side_subs.each do |sub|
            sub_val = sub[:total].to_f.round(2)
            sub_pct = val.zero? ? 0 : (sub_val / val * 100).round(1)
            sub_color = sub[:category].color.presence || color
            sub_key = "#{key_prefix}#{prefix}_sub_#{sub[:category].id}"
            sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color)

            if flow_direction == :inbound
              links << { source: sub_idx, target: parent_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            else
              links << { source: parent_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            end
          end
        else
          idx = add_node.call(node_key, ct.category.name, val, percentage, color)

          if flow_direction == :inbound
            links << { source: idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: idx, value: val, color: color, percentage: percentage }
          end
        end

        # Render opposite-direction subcategories as standalone nodes on this side,
        # linked directly to cash_flow. They represent subcategory surplus/deficit
        # that goes against the parent's overall direction.
        opposite_prefix = flow_direction == :inbound ? "expense" : "income"
        opposite_subs.each do |sub|
          sub_val = sub[:total].to_f.round(2)
          sub_pct = total.zero? ? 0 : (sub_val / total * 100).round(1)
          sub_color = sub[:category].color.presence || color
          sub_key = "#{key_prefix}#{opposite_prefix}_sub_#{sub[:category].id}"
          sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color)

          # Opposite direction: if parent is outbound (expense), this sub is inbound (income)
          if flow_direction == :inbound
            links << { source: cash_flow_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          else
            links << { source: sub_idx, target: cash_flow_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          end
        end
      end
    end

    def build_split_cashflow_sankey_data(accounts:, period:, currency:)
      nodes = []
      links = []
      node_indices = {}
      account_lane_order = accounts.each_with_index.to_h { |account, idx| [ account.id, idx ] }

      add_node = ->(unique_key, display_name, value, percentage, color) {
        node_indices[unique_key] ||= begin
          metadata = split_sankey_node_metadata(unique_key, account_lane_order)
          nodes << {
            name: display_name,
            value: value.to_f.round(2),
            percentage: percentage.to_f.round(1),
            color: color
          }.merge(metadata)
          nodes.size - 1
        end
      }

      income_flows_by_account_category = Hash.new(0.to_d)
      expense_flows_by_account_category = Hash.new(0.to_d)
      income_totals_by_category = Hash.new(0.to_d)
      expense_totals_by_category = Hash.new(0.to_d)
      income_totals_by_account = Hash.new(0.to_d)
      expense_totals_by_account = Hash.new(0.to_d)
      income_categories_by_key = {}
      expense_categories_by_key = {}

      accounts.each do |account|
        income_statement = Current.family.income_statement(user: Current.user, account_ids: [ account.id ])
        net_totals = income_statement.net_category_totals(period: period)

        net_totals.net_income_categories.each do |category_total|
          value = category_total.total.to_d
          next if value.zero?

          category_key = split_category_key(category_total)
          income_flows_by_account_category[[ account.id, category_key ]] += value
          income_totals_by_category[category_key] += value
          income_totals_by_account[account.id] += value
          income_categories_by_key[category_key] ||= category_total.category
        end

        net_totals.net_expense_categories.each do |category_total|
          value = category_total.total.to_d
          next if value.zero?

          category_key = split_category_key(category_total)
          expense_flows_by_account_category[[ account.id, category_key ]] += value
          expense_totals_by_category[category_key] += value
          expense_totals_by_account[account.id] += value
          expense_categories_by_key[category_key] ||= category_total.category
        end
      end

      transfer_overlay_data = build_split_transfer_overlays(accounts: accounts, period: period, currency: currency)
      transfer_totals_by_account = transfer_overlay_data[:totals_by_account]

      total_income = income_totals_by_category.values.sum.to_f.round(2)
      total_expense = expense_totals_by_category.values.sum.to_f.round(2)

      income_node_indices = {}
      income_totals_by_category.sort_by { |_, value| -value.to_f }.each do |category_key, value|
        category = split_category_for_key(category_key, category_lookup: income_categories_by_key)
        percentage = total_income.zero? ? 0 : (value.to_f / total_income * 100).round(1)
        income_node_indices[category_key] = add_node.call(
          "split_income_#{category_key}",
          category.name,
          value.to_f.round(2),
          percentage,
          category.color.presence || Category::UNCATEGORIZED_COLOR
        )
      end

      expense_node_indices = {}
      expense_totals_by_category.sort_by { |_, value| -value.to_f }.each do |category_key, value|
        category = split_category_for_key(category_key, category_lookup: expense_categories_by_key)
        percentage = total_expense.zero? ? 0 : (value.to_f / total_expense * 100).round(1)
        expense_node_indices[category_key] = add_node.call(
          "split_expense_#{category_key}",
          category.name,
          value.to_f.round(2),
          percentage,
          category.color.presence || Category::UNCATEGORIZED_COLOR
        )
      end

      account_node_indices = {}
      accounts.each do |account|
        has_category_flows = income_totals_by_account[account.id].positive? || expense_totals_by_account[account.id].positive?
        next unless has_category_flows

        node_value = [
          income_totals_by_account[account.id].to_f,
          expense_totals_by_account[account.id].to_f,
          transfer_totals_by_account[account.id].to_f
        ].max.round(2)

        account_node_indices[account.id] = add_node.call(
          "account_#{account.id}_cash_flow_node",
          account.name,
          node_value,
          100.0,
          "var(--color-success)"
        )
      end

      income_flows_by_account_category.each do |(account_id, category_key), value|
        account_idx = account_node_indices[account_id]
        income_idx = income_node_indices[category_key]
        next unless account_idx && income_idx

        category = split_category_for_key(category_key, category_lookup: income_categories_by_key)
        percentage = total_income.zero? ? 0 : (value.to_f / total_income * 100).round(1)
        links << {
          source: income_idx,
          target: account_idx,
          value: value.to_f.round(2),
          color: category.color.presence || Category::UNCATEGORIZED_COLOR,
          percentage: percentage
        }
      end

      expense_flows_by_account_category.each do |(account_id, category_key), value|
        account_idx = account_node_indices[account_id]
        expense_idx = expense_node_indices[category_key]
        next unless account_idx && expense_idx

        category = split_category_for_key(category_key, category_lookup: expense_categories_by_key)
        percentage = total_expense.zero? ? 0 : (value.to_f / total_expense * 100).round(1)
        links << {
          source: account_idx,
          target: expense_idx,
          value: value.to_f.round(2),
          color: category.color.presence || Category::UNCATEGORIZED_COLOR,
          percentage: percentage
        }
      end

      transfer_overlays = transfer_overlay_data[:links].filter_map do |flow|
        source_idx = account_node_indices[flow[:source_account_id]]
        target_idx = account_node_indices[flow[:target_account_id]]
        next unless source_idx && target_idx

        {
          source: source_idx,
          target: target_idx,
          value: flow[:value].to_f.round(2),
          color: Category::TRANSFER_COLOR,
          flow_type: "transfer_overlay",
          source_name: flow[:source_name],
          target_name: flow[:target_name]
        }
      end

      {
        nodes: nodes,
        links: links,
        transfer_overlays: transfer_overlays,
        currency_symbol: Money::Currency.new(currency).symbol
      }
    end

    def split_sankey_node_metadata(unique_key, account_lane_order)
      account_id = unique_key[/\Aaccount_([^_]+)_/, 1]
      return {} unless account_id

      {
        lane_order: account_lane_order.fetch(account_id, 0),
        node_role: split_sankey_node_role(unique_key)
      }
    end

    def split_category_key(category_total)
      category = category_total.category
      category.id.presence || category.name
    end

    def split_category_for_key(category_key, category_lookup:)
      category_lookup.fetch(category_key)
    end

    def split_sankey_node_role(unique_key)
      return "cash_flow" if unique_key.end_with?("_cash_flow_node")
      return "surplus" if unique_key.end_with?("_surplus_node")
      return "transfer_in" if unique_key.include?("_transfer_in_")
      return "transfer_out" if unique_key.include?("_transfer_out_")
      return "income_sub" if unique_key.include?("_income_sub_")
      return "income" if unique_key.include?("_income_")
      return "expense_sub" if unique_key.include?("_expense_sub_")
      return "expense" if unique_key.include?("_expense_")

      "other"
    end

    def build_split_transfer_overlays(accounts:, period:, currency:)
      accounts_by_id = accounts.index_by(&:id)
      account_ids = accounts_by_id.keys.to_set

      transfer_transactions = Current.family.transactions
        .visible
        .excluding_pending
        .in_period(period)
        .where(kind: Transaction::TRANSFER_KINDS)
        .where(entries: { excluded: false })
        .includes(
          :entry,
          transfer_as_outflow: { inflow_transaction: { entry: :account } }
        )

      outflow_transactions = transfer_transactions.select(&:transfer_as_outflow)
      return { links: [], totals_by_account: Hash.new(0.to_d) } if outflow_transactions.empty?

      exchange_rates = exchange_rate_map_for_entries(outflow_transactions.map(&:entry), target_currency: currency)
      directed_buckets = Hash.new(0.to_d)

      outflow_transactions.each do |transaction|
        source_entry = transaction.entry
        destination_entry = transaction.transfer_as_outflow&.inflow_transaction&.entry
        next unless source_entry && destination_entry

        source_account = source_entry.account
        destination_account = destination_entry.account
        next unless source_account && destination_account
        next unless account_ids.include?(source_account.id) && account_ids.include?(destination_account.id)

        converted_amount = converted_entry_abs_amount(source_entry, target_currency: currency, exchange_rates: exchange_rates)
        next if converted_amount.zero?

        directed_buckets[[ source_account.id, destination_account.id ]] += converted_amount
      end

      links = []
      totals_by_account = Hash.new(0.to_d)
      pair_keys = directed_buckets.keys.map { |source_id, target_id| [ source_id, target_id ].sort }.uniq

      pair_keys.each do |account_a_id, account_b_id|
        forward = directed_buckets[[ account_a_id, account_b_id ]]
        reverse = directed_buckets[[ account_b_id, account_a_id ]]
        net_amount = forward - reverse
        next if net_amount.zero?

        source_id, target_id = net_amount.positive? ? [ account_a_id, account_b_id ] : [ account_b_id, account_a_id ]
        source_account = accounts_by_id[source_id]
        target_account = accounts_by_id[target_id]
        next unless source_account && target_account

        value = net_amount.abs.round(2)

        links << {
          source_account_id: source_id,
          target_account_id: target_id,
          source_name: source_account.name,
          target_name: target_account.name,
          value: value
        }

        totals_by_account[source_id] += value
        totals_by_account[target_id] += value
      end

      {
        links: links.sort_by { |flow| -flow[:value].to_f },
        totals_by_account: totals_by_account
      }
    end

    def build_transfer_flows_for_account(account:, period:, currency:, accessible_account_ids:)
      transfer_transactions = Current.family.transactions
        .visible
        .excluding_pending
        .in_period(period)
        .where(kind: Transaction::TRANSFER_KINDS)
        .where(entries: { account_id: account.id, excluded: false })
        .includes(
          :entry,
          transfer_as_outflow: { inflow_transaction: { entry: :account } },
          transfer_as_inflow: { outflow_transaction: { entry: :account } }
        )

      return { inbound: [], outbound: [], total_inbound: 0.0, total_outbound: 0.0 } if transfer_transactions.empty?

      exchange_rates = exchange_rate_map_for_entries(transfer_transactions.map(&:entry), target_currency: currency)
      buckets = {
        inbound: Hash.new(0.to_d),
        outbound: Hash.new(0.to_d)
      }

      transfer_transactions.each do |transaction|
        entry = transaction.entry
        next unless entry

        counterparty = transfer_counterparty_account(transaction)
        next unless counterparty
        next unless accessible_account_ids.include?(counterparty.id)

        converted_amount = converted_entry_abs_amount(entry, target_currency: currency, exchange_rates: exchange_rates)
        next if converted_amount.zero?

        direction = entry.amount.positive? ? :outbound : :inbound
        buckets[direction][counterparty] += converted_amount
      end

      inbound = buckets[:inbound].map do |counterparty, amount|
        {
          key: counterparty.id,
          name: counterparty.name,
          value: amount.to_f.round(2)
        }
      end.sort_by { |flow| -flow[:value] }

      outbound = buckets[:outbound].map do |counterparty, amount|
        {
          key: counterparty.id,
          name: counterparty.name,
          value: amount.to_f.round(2)
        }
      end.sort_by { |flow| -flow[:value] }

      {
        inbound: inbound,
        outbound: outbound,
        total_inbound: inbound.sum { |flow| flow[:value] }.round(2),
        total_outbound: outbound.sum { |flow| flow[:value] }.round(2)
      }
    end

    def transfer_counterparty_account(transaction)
      if (outflow_transfer = transaction.transfer_as_outflow)
        outflow_transfer.inflow_transaction&.entry&.account
      elsif (inflow_transfer = transaction.transfer_as_inflow)
        inflow_transfer.outflow_transaction&.entry&.account
      end
    end

    def exchange_rate_map_for_entries(entries, target_currency:)
      rate_keys = entries.filter_map do |entry|
        next if entry.currency == target_currency

        [ entry.date, entry.currency ]
      end.uniq

      return {} if rate_keys.empty?

      dates = rate_keys.map(&:first).uniq
      currencies = rate_keys.map(&:last).uniq

      ExchangeRate
        .where(date: dates, from_currency: currencies, to_currency: target_currency)
        .pluck(:date, :from_currency, :rate)
        .to_h { |date, from_currency, rate| [ [ date, from_currency ], rate.to_d ] }
    end

    def converted_entry_abs_amount(entry, target_currency:, exchange_rates:)
      rate = if entry.currency == target_currency
        1.to_d
      else
        exchange_rates.fetch([ entry.date, entry.currency ], 1.to_d)
      end

      (entry.amount.to_d.abs * rate).round(2)
    end

    def resolved_sankey_mode
      mode = params[:sankey_mode].presence
      mode.in?(%w[aggregate split]) ? mode : "aggregate"
    end

    def build_outflows_donut_data(net_totals)
      currency_symbol = Money::Currency.new(net_totals.currency).symbol
      total = net_totals.total_net_expense

      categories = net_totals.net_expense_categories
        .reject { |ct| ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon,
            clickable: !ct.category.other_investments?
          }
        end

      { categories: categories, total: total.to_f.round(2), currency: net_totals.currency, currency_symbol: currency_symbol }
    end

    def ensure_intro_guest!
      return if Current.user&.guest?

      redirect_to root_path, alert: t("pages.intro.not_authorized", default: "Intro is only available to guest users.")
    end
end
