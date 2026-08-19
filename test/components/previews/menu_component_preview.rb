class MenuComponentPreview < ViewComponent::Preview
  def icon
    render DS::Menu.new(variant: "icon") do |menu|
      menu_contents(menu)
    end
  end

  def icon_sm
    render DS::Menu.new(variant: "icon_sm") do |menu|
      menu_contents(menu)
    end
  end

  def button
    render DS::Menu.new(variant: "button") do |menu|
      menu.with_button(text: "Open menu", variant: "secondary")
      menu_contents(menu)
    end
  end

  # Single-select list. `selected:` reserves a fixed-width leading check gutter
  # so the selected row's text stays aligned with every other row.
  def selectable
    render DS::Menu.new(variant: "button") do |menu|
      menu.with_button(text: "30D", variant: "secondary")
      menu.with_item(variant: "link", text: "7D", href: "#", selected: false)
      menu.with_item(variant: "link", text: "30D", href: "#", selected: true)
      menu.with_item(variant: "link", text: "90D", href: "#", selected: false)
      menu.with_item(variant: "link", text: "Year to Date", href: "#", selected: false)
    end
  end

  private
    def menu_contents(menu)
      menu.with_item(variant: "link", text: "Link", href: "#", icon: "plus")
      menu.with_item(variant: "button", text: "Action", href: "#", method: :post, icon: "circle")
      menu.with_item(variant: "button", text: "Action destructive", href: "#", method: :delete, icon: "circle")

      menu.with_item(variant: "divider")

      menu.with_item(variant: "link", text: "Another link", href: "#", icon: "external-link")
    end
end
