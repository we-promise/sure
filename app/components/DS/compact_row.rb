class DS::CompactRow < DesignSystemComponent
  # Shared flex/fixed-width shell for the compact transaction/trade/valuation/
  # split-parent rows. Extracted so the date, lock-icon, and balance columns
  # stay pixel-aligned across every row type instead of being hand-copied
  # (and drifting) in each partial.
  #
  #   <%= render DS::CompactRow.new(show_date: has_running_balance, show_balance: show_balance) do |row| %>
  #     <% row.with_checkbox { check_box_tag(...) } %>
  #     <% row.with_date { format_date(entry.date) } %>
  #     <% row.with_primary { ... } %>
  #     <% row.with_notes { ... } %>
  #     <% row.with_category { ... } %>
  #     <% row.with_amount { ... } %>
  #     <% row.with_balance { format_money(running_balance) } %>
  #   <% end %>
  renders_one :checkbox
  renders_one :date
  renders_one :primary
  renders_one :notes
  renders_one :category
  renders_one :amount
  renders_one :balance

  def initialize(show_date: false, show_balance: false, muted: false, indent: false, class: nil)
    @show_date = show_date
    @show_balance = show_balance
    @muted = muted
    @indent = indent
    @extra_class = binding.local_variable_get(:class)
  end

  def row_classes
    class_names(
      "group flex items-center gap-2 lg:gap-3 text-sm font-medium py-2 px-3",
      @indent ? "pl-6 lg:pl-8" : nil,
      @muted ? "opacity-50 text-secondary" : "text-primary",
      @extra_class
    )
  end

  erb_template <<~ERB
    <div class="<%= row_classes %>">
      <div class="hidden lg:flex w-8 shrink-0 justify-center">
        <%= checkbox %>
      </div>

      <% if @show_date %>
        <div class="hidden lg:flex w-[110px] shrink-0 text-secondary text-sm truncate pr-2"><%= date %></div>
      <% end %>

      <div class="flex items-center gap-2 lg:gap-3 flex-[2] min-w-0 pr-2">
        <%= primary %>
      </div>

      <div class="hidden lg:flex min-w-0 flex-[2] px-2">
        <% if notes? %>
          <%= notes %>
        <% else %>
          <span class="text-secondary/40 text-sm">—</span>
        <% end %>
      </div>

      <div class="hidden md:flex min-w-0 items-center gap-1 flex-[1]">
        <% if category? %>
          <%= category %>
        <% else %>
          <span class="text-secondary/40 text-sm">—</span>
        <% end %>
      </div>

      <div class="w-[120px] shrink-0 flex items-center justify-end gap-2">
        <%= amount %>
      </div>

      <% if @show_balance %>
        <div class="hidden lg:flex w-[120px] shrink-0 justify-end px-2">
          <%= balance %>
        </div>
      <% end %>
    </div>
  ERB
end
