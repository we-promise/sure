require "test_helper"

class Transactions::AttachmentUploadLocalizationViewTest < ActionView::TestCase
  setup do
    Current.session = Session.create!(user: users(:family_admin))
  end

  test "attachment actions use explicit locale plural rules for every allowed count and unchanged limits" do
    transaction = entries(:transaction).entryable
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        html = Nokogiri::HTML.fragment(render(partial: "transactions/attachments", locals: { transaction: transaction, can_upload: true }))
        form = html.at_css("form[data-controller='attachment-upload']")
        assert form
        remaining = Transaction::MAX_ATTACHMENTS_PER_TRANSACTION - transaction.attachments.count
        assert_equal remaining.to_s, form["data-attachment-upload-max-files-value"]
        assert_equal Transaction::MAX_ATTACHMENT_SIZE.to_s, form["data-attachment-upload-max-size-value"]
        assert form["data-attachment-upload-labels-value"], "#{locale} attachment labels must be supplied"
        labels = JSON.parse(form["data-attachment-upload-labels-value"])
        assert_equal I18n.t("transactions.attachments.upload", fallback: false, raise: true), labels.fetch("upload")
        assert_equal I18n.t("upload_interface.too_many_files", max: remaining, fallback: false, raise: true), labels.fetch("too_many_files")
        assert_equal I18n.t("upload_interface.file_too_large", max: Transaction::MAX_ATTACHMENT_SIZE / 1.megabyte, fallback: false, raise: true), labels.fetch("file_too_large")
        assert_equal (1..remaining).map(&:to_s), labels.fetch("upload_files").keys
        (1..remaining).each do |count|
          assert_equal I18n.t("upload_interface.upload_files", count: count, fallback: false, raise: true), labels.fetch("upload_files").fetch(count.to_s), "#{locale}: count #{count}"
        end
      end
    end
  end
end
