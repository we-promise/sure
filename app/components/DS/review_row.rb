class DS::ReviewRow < DesignSystemComponent
  # A question and the buttons that answer it: text on the left, actions on
  # the right, and the actions dropped under the text when the row is narrower
  # than @md. Beside the text on a phone they took most of the row and cut
  # the question down to "VERIZON …". Extracted from the Bills "Needs review"
  # queue and the "Possible new bills" strip, which hand-built the same row
  # (#3921 review).
  #
  # The content is the text; the actions slot holds the buttons:
  #
  #   <%= render DS::ReviewRow.new do |row| %>
  #     <% row.with_actions do %>
  #       <%= render DS::Link.new(text: t(".confirm"), variant: "primary", href: path, method: :post) %>
  #     <% end %>
  #     <p class="text-sm text-primary @md:truncate"><%= name %></p>
  #   <% end %>
  #
  # The row is its own query container, so `@md:` classes in the content
  # (truncating a title once there's room beside the buttons) follow the row's
  # width, not the viewport's.
  renders_one :actions
end
