require "test_helper"

class StyledFormBuilderTest < ActionView::TestCase
  setup do
    @builder = StyledFormBuilder.new(:account_statement, nil, self, {})
  end

  test "a labelled file field sits in a form field with its label" do
    field = Nokogiri::HTML.fragment(@builder.file_field(:files, label: "Statement files")).at(".form-field")

    assert field, "expected the file input wrapped in a .form-field"
    assert_equal "account_statement_files", field.at("label.form-field__label")["for"]
    assert_includes field.at("input[type=file]")["class"].split, "file:bg-container-inset"
  end

  # text-destructive inverts in dark mode; a raw palette class does not.
  test "a required field marks its label with the destructive token" do
    field = Nokogiri::HTML.fragment(@builder.text_field(:name, label: "Name", required: true))
    marker = field.at("label.form-field__label span")

    assert marker, "expected a required marker in the label"
    assert_equal "*", marker.text
    assert_includes marker["class"].split, "text-destructive"
  end

  # The dropzones pass `hidden` and draw their own target: no wrapper, and
  # their classes merged in rather than replaced.
  test "an unlabelled file field comes back bare and keeps the caller's classes" do
    fragment = Nokogiri::HTML.fragment(@builder.file_field(:files, class: "hidden"))

    assert_nil fragment.at(".form-field")
    assert_includes fragment.at("input[type=file]")["class"].split, "hidden"
  end

  test "a money field rounds to the currency's precision by default" do
    usd = Money::Currency.new("USD")

    assert_equal "3.22", @builder.money_field_text(BigDecimal("3.224201"), usd)
    assert_equal "3.2242", @builder.money_field_text(BigDecimal("3.224201"), usd, precision: 4)
    assert_equal "0.00", @builder.money_field_text(0, usd)
    assert_nil @builder.money_field_text(nil, usd)
  end

  test "a step any money field keeps every stored decimal" do
    usd = Money::Currency.new("USD")

    assert_equal "3.224201", @builder.money_field_text(BigDecimal("3.224201"), usd, step: "any")
    assert_equal "150.00", @builder.money_field_text(BigDecimal("150"), usd, step: "any")
    assert_equal "-0.000002891", @builder.money_field_text(BigDecimal("-0.000002891"), usd, step: "any")
    assert_equal "1500", @builder.money_field_text(BigDecimal("1500"), Money::Currency.new("JPY"), step: "any")
    assert_equal "12.50", @builder.money_field_text(Money.new(12.5, "USD"), usd, step: "any")
    assert_equal "1.23", @builder.money_field_text(BigDecimal("1.23456"), usd, step: "any", precision: 2)
  end

  test "blank_zero leaves a zero money field empty" do
    usd = Money::Currency.new("USD")

    assert_nil @builder.money_field_text(BigDecimal("0"), usd, step: "any", blank_zero: true)
    assert_equal "9.95", @builder.money_field_text(BigDecimal("9.95"), usd, step: "any", blank_zero: true)
  end
end
