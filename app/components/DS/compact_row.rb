class DS::CompactRow < DesignSystemComponent
  # Shared flex/fixed-width shell for the compact transaction/trade/valuation/
  # split-parent rows (and their matching column header). Extracted so the
  # date, lock-icon, and balance columns stay pixel-aligned across every row
  # type instead of being hand-copied (and drifting) in each partial.
  #
  #   <%= render DS::CompactRow.new(show_date: has_running_balance, show_balance: show_balance) do |row| %>
  #     <% row.with_checkbox { check_box_tag(...) } %>
  #     <% row.with_date { format_date(entry.date) } %>
  #     <% row.with_primary { ... } %>
  #     <% row.with_notes { ... } %>
  #     <% row.with_category { ... } %>
  #     <% row.with_labels { ... } %>
  #     <% row.with_amount { ... } %>
  #     <% row.with_balance { format_money(running_balance) } %>
  #   <% end %>
  #
  # Pass `header: true` to render the same column shell as an uppercase,
  # secondary-colored label row (used for the list's column headers), so
  # header labels can never drift out of alignment with the data rows below
  # them — both are built from the exact same column widths.
  # Place the table inside an @container/compact-table wrapper. Below 48rem
  # of available table width, rows use their mobile content and amount only;
  # the optional Notes and Labels cells additionally wait for 64rem (@5xl).
  #
  #   <%= render DS::CompactRow.new(header: true, show_date: true) do |row| %>
  #     <% row.with_date { t("transactions.show.date_label") } %>
  #     <% row.with_primary { t("transactions.list.transaction") } %>
  #     ...
  #   <% end %>
  renders_one :checkbox
  renders_one :date
  renders_one :primary
  renders_one :notes
  renders_one :category
  renders_one :labels
  renders_one :amount
  renders_one :balance

  def initialize(show_date: false, show_balance: false, show_notes: true, muted: false, indent: false, header: false, data: {}, class: nil)
    @show_date = show_date
    @show_balance = show_balance
    @show_notes = show_notes
    @muted = muted
    @indent = indent
    @header = header
    @data = data
    @extra_class = binding.local_variable_get(:class)
  end

  # Root flex shell shared by data rows and header labels, so columns stay
  # pixel-aligned. Headers render label typography with matching inset.
  def row_classes
    class_names(
      "flex items-center gap-2",
      # Header labels must start at the same x as row content: the header
      # sits in an outer px-2 wrapper, so the header shell needs its own
      # px-2 to reach the 16px inset of data rows (outer p-1 + row px-3).
      @header ? "text-xs uppercase font-medium text-secondary px-2" : row_type_classes,
      @extra_class
    )
  end

  # Table semantics for the div-based layout: headers expose columnheaders,
  # data rows expose cells.
  def cell_role
    @header ? "columnheader" : "cell"
  end

  # Checkbox column shell. Data rows reveal it on small containers once the
  # bulk-select toggle unhides the input; headers never reveal it.
  def checkbox_wrapper_classes
    class_names(
      "w-6 shrink-0 justify-center hidden @3xl/compact-table:flex",
      @header ? nil : "has-[input:not(.hidden)]:flex"
    )
  end

  erb_template <<~ERB
    <%= tag.div class: row_classes, data: @data, role: "row" do %>
      <div role="<%= cell_role %>" class="<%= checkbox_wrapper_classes %>">
        <%= checkbox %>
      </div>

      <% if @show_date %>
        <div role="<%= cell_role %>" class="hidden @3xl/compact-table:flex w-24 shrink-0 text-secondary text-sm truncate pr-2"><%= date %></div>
      <% end %>

      <div role="<%= cell_role %>" class="flex items-center gap-2 @3xl/compact-table:gap-3 flex-[5] min-w-0">
        <%= primary %>
      </div>

      <% if @show_notes %>
        <div role="<%= cell_role %>" class="hidden @5xl/compact-table:flex min-w-0 flex-[5]">
          <% if notes? %>
            <%= notes %>
          <% else %>
            <span class="text-secondary opacity-40 text-sm">—</span>
          <% end %>
        </div>
      <% end %>

      <div role="<%= cell_role %>" class="hidden @3xl/compact-table:flex min-w-0 items-center gap-1 flex-[2]">
        <% if category? %>
          <%= category %>
        <% else %>
          <span class="text-secondary opacity-40 text-sm">—</span>
        <% end %>
      </div>

      <div role="<%= cell_role %>" class="hidden @5xl/compact-table:flex w-30 shrink-0 min-w-0 items-center whitespace-nowrap" data-tag-fit-bounds="1">
        <%= labels %>
      </div>

      <div role="<%= cell_role %>" class="w-30 shrink-0 flex items-center justify-end gap-2 tabular-nums">
        <%= amount %>
      </div>

      <% if @show_balance %>
        <div role="<%= cell_role %>" class="hidden @3xl/compact-table:flex w-30 shrink-0 justify-end tabular-nums">
          <%= balance %>
        </div>
      <% end %>
    <% end %>
  ERB

  private
    def row_type_classes
      class_names(
        "group text-sm font-medium py-2 px-3",
        @indent ? "pl-6 @3xl/compact-table:pl-8" : nil,
        @muted ? "opacity-50 text-secondary" : "text-primary"
      )
    end
end
