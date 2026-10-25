require "test_helper"

class UploadInterfaceLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @import = imports(:transaction)
  end

  test "CSV QIF and Sure upload pages supply localized safe progress templates" do
    qif = @user.family.imports.create!(type: "QifImport")
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      [ @import, qif, imports(:sure) ].each do |import|
        get import_upload_path(import), params: { locale: locale }
        assert_response :success
        assert_select "[data-controller~='file-upload']" do |nodes|
          assert nodes.any?
          nodes.each do |node|
            assert_equal translation("upload_interface.uploading", locale, filename: "%{filename}"), node["data-file-upload-uploading-value"]
          end
        end
        unless import.is_a?(QifImport)
          assert_select "[data-controller~='drag-and-drop-import']" do |nodes|
            key = import.is_a?(TransactionImport) ? "icost_imports.parse_errors.unsupported_file_type" : "imports.create.invalid_file_type"
            nodes.each { |node| assert_equal translation(key, locale), node["data-drag-and-drop-import-invalid-file-type-value"] }
          end
        end
        assert_select ".translation_missing", count: 0
      end
    end
  end

  test "transaction list supplies the same localized CSV error" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get transactions_path, params: { locale: locale }
      assert_response :success
      assert_select "#transactions[data-controller~='drag-and-drop-import']" do |nodes|
        assert_equal translation("imports.create.invalid_file_type", locale), nodes.first["data-drag-and-drop-import-invalid-file-type-value"]
      end
    end
  end

  test "invalid QIF upload translates the error and does not change the pending import" do
    qif = @user.family.imports.create!(type: "QifImport")
    before = qif.attributes
    assert_no_difference [ "Import::Row.count", "Entry.count" ] do
      LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
        patch import_upload_path(qif), params: { locale: locale, import: { raw_file_str: "synthetic invalid QIF" } }
        assert_response :unprocessable_entity
        assert_equal translation("upload_interface.qif_invalid", locale), flash[:alert]
        assert_equal before, qif.reload.attributes
      end
    end
  end

  test "amount strategy choices translate labels while retaining persisted values and CSV content" do
    @import.update!(raw_file_str: "Date,Name,Amount\n2026-01-02,Synthetic Original,12.34\n", col_sep: ",")
    before = @import.attributes
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get import_configuration_path(@import), params: { locale: locale }
      assert_response :success
      Import::AMOUNT_TYPE_STRATEGIES.each do |strategy|
        assert_select "select[name='import[amount_type_strategy]'] option[value=?]", strategy,
          text: translation("upload_interface.amount_type_strategies.#{strategy}", locale)
      end
      assert_includes response.body, "Synthetic Original"
      assert_equal before, @import.reload.attributes
    end
  end

  private
    def translation(key, locale, **options)
      I18n.t(key, locale: locale, fallback: false, raise: true, **options)
    end
end
