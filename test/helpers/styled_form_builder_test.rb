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

  # Without a max, Chrome lets the year segment take six digits, so typing
  # "20261125" leaves the year at 202611.
  test "a date field caps its year at four digits by default" do
    field = Nokogiri::HTML.fragment(@builder.date_field(:period_start_on, label: "Start"))

    assert_equal "9999-12-31", field.at("input[type=date]")["max"]
    assert field.at(".form-field"), "expected the date input to stay styled"
  end

  test "a date field keeps the max its caller sets" do
    field = Nokogiri::HTML.fragment(@builder.date_field(:period_start_on, max: Date.new(2026, 11, 25)))

    assert_equal "2026-11-25", field.at("input[type=date]")["max"]
  end

  test "a date field given a nil max renders without one" do
    field = Nokogiri::HTML.fragment(@builder.date_field(:period_start_on, max: nil))

    assert_nil field.at("input[type=date]")["max"]
  end
end
