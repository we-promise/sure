require "test_helper"

class Import::ConfigurationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = imports(:transaction)
  end

  test "show" do
    get import_configuration_url(@import)
    assert_response :success
  end

  test "auto detection preserves timestamp and the selected accounting date policy" do
    @user.family.update!(timezone: "Europe/Paris")
    @import.update!(raw_file_str: "Datetime,Amount\n2026-09-17T23:30:00Z,12\n")

    patch import_configuration_url(@import), params: { import: {
      date_col_label: "Datetime", date_format: "auto", amount_col_label: "Amount", date_basis: "local"
    } }

    assert_redirected_to import_clean_url(@import)
    assert_equal "iso8601", @import.reload.date_format
    assert_equal "Europe/Paris", @import.date_timezone
    assert_equal "2026-09-18", @import.rows.first.date_iso
    assert_equal Time.utc(2026, 9, 17, 23, 30), @import.rows.first.transacted_at_time
  end

  test "a template uses the current family timezone for a new import" do
    @user.family.update!(timezone: "Europe/Paris")
    template = @user.family.imports.create!(type: "TransactionImport", account: @import.account,
      raw_file_str: "Datetime,Amount\n2026-09-17T23:30:00Z,12\n", date_col_label: "Datetime",
      date_format: "iso8601", amount_col_label: "Amount", date_basis: "local")
    template.date_timezone = "Europe/Paris"
    template.save!
    @user.family.update!(timezone: "America/New_York")
    @import.update!(raw_file_str: template.raw_file_str)

    @import.apply_template!(template)
    @import.generate_rows_from_csv

    assert_equal "America/New_York", @import.reload.date_timezone
    assert_equal "2026-09-17", @import.rows.first.date_iso
  end

  test "ambiguous dates require an explicit format instead of a family preference" do
    @import.update!(raw_file_str: "Date,Amount\n03/04/2026,12\n")

    patch import_configuration_url(@import), params: { import: {
      date_col_label: "Date", date_format: "auto", amount_col_label: "Amount"
    } }

    assert_redirected_to import_configuration_url(@import)
    assert_match "ambiguous", flash[:alert]
    assert_empty @import.reload.rows
    assert_not @import.publishable?

    patch import_configuration_url(@import), params: { import: { date_format: "%d/%m/%Y" } }
    assert_redirected_to import_clean_url(@import)
    assert_equal "2026-04-03", @import.reload.rows.first.date_iso
  end

  test "refreshing the format preview preserves other column choices" do
    @import.update!(raw_file_str: "Datetime,Amount\n2026-09-17T23:30:00Z,12\n")
    patch import_configuration_url(@import), params: { refresh_only: true, import: {
      date_col_label: "Datetime", date_format: "auto", amount_col_label: "Amount", date_basis: "source"
    } }

    assert_redirected_to import_configuration_url(@import)
    assert_equal "Amount", @import.reload.amount_col_label
    follow_redirect!
    assert_response :success
    assert_select "option[value='iso8601']"
    assert_includes response.body, "2026-09-17"
  end

  test "timestamp preview displays seconds without discarding imported precision" do
    @user.family.update!(timezone: "Europe/Paris")
    @import.update!(raw_file_str: "Datetime,Amount\n2026-09-17T14:48:50.123456Z,12\n",
      date_col_label: "Datetime", date_format: "iso8601")

    get import_configuration_url(@import)

    assert_response :success
    assert_select "p[aria-live='polite']", text: /2026-09-17T16:48:50\+02:00/
    assert_equal Time.iso8601("2026-09-17T14:48:50.123456Z"), @import.date_preview.timestamp
  end

  test "invalid separate timestamp still allows revisiting configuration" do
    @import.update!(raw_file_str: "Date,Occurred,Amount\n2026-09-17,bad-timestamp,12\n",
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred")
    get import_configuration_url(@import)
    assert_response :success
    assert_includes response.body, I18n.t("imports.timestamps.invalid_preview")
  end

  test "changing a mapped column for preview invalidates old rows and mappings" do
    @import.update!(raw_file_str: "Date,Other,Amount\n2026-09-17,2026-09-18,12\n",
      date_col_label: "Date", date_format: "%Y-%m-%d", amount_col_label: "Amount", account: accounts(:depository))
    @import.generate_rows_from_csv
    @import.sync_mappings
    assert @import.reload.publishable?

    patch import_configuration_url(@import), params: { refresh_only: true, import: { date_col_label: "Other" } }
    assert_redirected_to import_configuration_url(@import)
    assert_empty @import.reload.rows
    assert_empty @import.mappings
    assert_not @import.publishable?
  end

  test "template suggestion renders German copy and preserves action destinations" do
    ensure_tailwind_build
    @user.update!(locale: "de")
    %w[template_found template_description manually_configure apply_template sample_caption].each do |key|
      assert I18n.exists?("import.configurations.show.#{key}", :de, fallback: false)
    end
    @user.family.imports.create!(type: "TransactionImport", status: "complete")

    get import_configuration_url(@import, template_hint: true)

    assert_response :success
    assert_select "h3", text: "Importvorlage gefunden"
    assert_select "p", text: "Wir haben eine Konfiguration aus einem früheren Import für dieses Konto gefunden. Möchtest du sie für diesen Import übernehmen?"
    assert_select "a[href=?]", import_configuration_path(@import), text: "Manuell konfigurieren"
    assert_select "form[action=?][method=post]", apply_template_import_path(@import) do
      assert_select "input[name=_method][value=put]"
      assert_select "button", text: "Vorlage übernehmen"
    end
  end

  test "template suggestion preserves English copy" do
    ensure_tailwind_build
    @user.update!(locale: "en")
    @user.family.imports.create!(type: "TransactionImport", status: "complete")

    get import_configuration_url(@import, template_hint: true)

    assert_response :success
    assert_select "h3", text: "Template configuration found"
    assert_select "p", text: "We found a configuration from a previous import for this account. Would you like to apply it to this import?"
    assert_select "a", text: "Manually configure"
    assert_select "button", text: "Apply template"
    get import_configuration_url(@import)
    assert_select "h2", text: "Sample data from your uploaded CSV"
  end

  test "manual configuration localizes the sample caption without translating CSV data" do
    ensure_tailwind_build
    @user.update!(locale: "de")
    @import.update!(raw_file_str: "Date,Name,Amount\n2026-01-02,Synthetic Sample,12.34\n", col_sep: ",")

    get import_configuration_url(@import, template_hint: true)

    assert_response :success
    assert_select "h2", text: "Beispieldaten aus deiner hochgeladenen CSV-Datei"
    assert_includes response.body, "Synthetic Sample"
    assert_select "h3", text: "Importvorlage gefunden", count: 0
  end

  test "show renders the YNAB configuration partial" do
    ynab = @user.family.imports.create!(
      type: "YnabImport",
      raw_file_str: file_fixture("imports/ynab.csv").read,
      col_sep: ","
    )

    get import_configuration_url(ynab)

    assert_response :success
  end

  test "updating a valid configuration regenerates rows" do
    TransactionImport.any_instance.expects(:generate_rows_from_csv).once

    patch import_configuration_url(@import), params: {
      import: {
        date_col_label: "Date",
        date_format: "%Y-%m-%d",
        name_col_label: "Name",
        category_col_label: "Category",
        tags_col_label: "Tags",
        amount_col_label: "Amount",
        signage_convention: "inflows_positive",
        account_col_label: "Account",
        number_format: "1.234,56"
      }
    }

    assert_redirected_to import_clean_url(@import)
    assert_equal "Import configured successfully.", flash[:notice]

    # Verify configurations were saved
    @import.reload
    assert_equal "Date", @import.date_col_label
    assert_equal "%Y-%m-%d", @import.date_format
    assert_equal "Name", @import.name_col_label
    assert_equal "Category", @import.category_col_label
    assert_equal "Tags", @import.tags_col_label
    assert_equal "Amount", @import.amount_col_label
    assert_equal "inflows_positive", @import.signage_convention
    assert_equal "Account", @import.account_col_label
    assert_equal "1.234,56", @import.number_format
  end
end
