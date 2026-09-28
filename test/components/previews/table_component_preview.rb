class TableComponentPreview < ViewComponent::Preview
  BILLS = [
    { name: "Rent", frequency: "Monthly", amount: "$1,500.00", status: "Active" },
    { name: "Streaming", frequency: "Monthly", amount: "$15.99", status: "Active" },
    { name: "Car insurance", frequency: "Every 6 months", amount: "$412.30", status: "Paused" }
  ].freeze

  # A table on the page background is a card of its own.
  # @display container_classes max-w-[640px]
  def default
    render DS::Table.new(rows: BILLS) do |table|
      table.with_column("Name") { |bill| bill[:name] }
      table.with_column("Frequency", class: "text-secondary") { |bill| bill[:frequency] }
      table.with_column("Amount", numeric: true) { |bill| bill[:amount] }
      table.with_column("Status") { |bill| bill[:status] }
    end
  end

  # Inside a card, the table sits in an inset frame, the way a list group does.
  # @display container_classes max-w-[640px]
  def inset
    render_with_template(template: "table_component_preview/inset")
  end

  # A long table caps its height and keeps the header in view. The label makes
  # the scroll area a named region a keyboard user can focus and scroll.
  # @display container_classes max-w-[640px]
  def sticky_header
    payments = (1..36).map { |number| { number: number, balance: 36_000 - number * 1_000 } }

    render DS::Table.new(rows: payments, sticky_header: true, label: "Payment schedule",
                         row_class: ->(payment) { "bg-container-inset" if payment[:number] <= 6 }) do |table|
      table.with_column("#", class: "text-secondary tabular-nums") { |payment| payment[:number].to_s }
      table.with_column("Payment", numeric: true) { "$1,000.00" }
      table.with_column("Remaining balance", numeric: true) { |payment| ActiveSupport::NumberHelper.number_to_currency(payment[:balance]) }
    end
  end
end
