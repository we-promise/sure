require "application_system_test_case"

class JavascriptLocalizationTest < ApplicationSystemTestCase
  test "Russian attachment counts and validation fit both viewport sizes" do
    user = sign_in_russian
    entry = user.family.entries.transactions.first

    [ 1400, 390 ].each do |width|
      page.current_window.resize_to(width, 900)
      visit transaction_path(entry)
      find("summary", text: /вложения/i).click
      form = find("[data-controller='attachment-upload']")
      page.scroll_to(form, align: :center)

      { 1 => "файл", 2 => "файла", 5 => "файлов" }.each do |count, noun|
        select_attachment_files(count)
        within(form) { assert_button "Загрузить #{count} #{noun}", disabled: false }
      end

      limit = form["data-attachment-upload-max-files-value"].to_i
      select_attachment_files(limit + 1)
      within(form) { assert_button "Слишком много файлов (максимум #{limit})", disabled: true }
      page.execute_script(<<~JS)
        const form = document.querySelector("[data-controller='attachment-upload']");
        const input = form.querySelector("input[type='file']");
        const transfer = new DataTransfer();
        transfer.items.add(new File([new Uint8Array(Number(form.dataset.attachmentUploadMaxSizeValue) + 1)], "large.pdf", {type: "application/pdf"}));
        input.files = transfer.files;
        input.dispatchEvent(new Event("change", {bubbles: true}));
      JS
      within(form) { assert_selector "button:disabled", text: "Слишком большой файл" }
      assert_no_selector ".translation_missing"
      assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")
      page.save_screenshot(Rails.root.join("tmp/screenshots/russian-attachments-#{width}.png"))
    end

    user.update!(locale: "de")
    visit transaction_path(entry)
    find("summary", text: Regexp.new(I18n.t("transactions.show.attachments", locale: :de), Regexp::IGNORECASE)).click
    assert_selector "[data-attachment-upload-locale-value='en']"
    select_attachment_files(2)
    assert_button "Upload 2 files", disabled: false
  end

  test "Russian SSO uses shared clipboard and restores the translated connection button" do
    sign_in_russian(users(:sure_support_staff))
    provider = SsoProvider.create!(strategy: "google_oauth2", name: "localization_test",
      label: "Localization check", client_id: "test-client", client_secret: "test-only", enabled: false)
    visit edit_admin_sso_provider_path(provider)
    button = find("button[data-action*='testConnection']")
    original_label = button.text
    button.click
    assert_selector "[data-admin-sso-form-target='testResult']", text: "Настройки Google OAuth2 прошли предварительную проверку"
    assert_button original_label, disabled: false

    page.execute_script(<<~JS)
      Object.defineProperty(navigator, "clipboard", { configurable: true, value: {
        writeText: text => { window.copiedCallback = text; return Promise.resolve(); }
      }});
    JS

    [ "openid_connect", "saml" ].each do |strategy|
      find("#sso_provider_strategy").find("option[value='#{strategy}']").select_option
      group = find("[data-controller='clipboard']", visible: true)
      expected = group.find("[data-clipboard-target='source']").text
      group.find("button").click
      assert_selector "[data-clipboard-target='iconSuccess']:not(.hidden)"
      assert_equal expected, page.evaluate_script("window.copiedCallback")
    end

    find("#sso_provider_strategy").find("option[value='openid_connect']").select_option
    page.execute_script(<<~JS)
      const realFetch = window.fetch;
      window.fetch = (url, options) => String(url).startsWith("https://issuer.example.test/")
        ? Promise.resolve(new Response(JSON.stringify({issuer: "https://issuer.example.test/realm/$&/"}), {status: 200}))
        : realFetch(url, options);
    JS
    issuer = find("#sso_provider_issuer")
    issuer.set("https://issuer.example.test/realm/$&")
    issuer.send_keys(:tab)
    assert_selector ".validation-message", text: "Адрес издателя не совпадает"
    assert_selector ".validation-message", text: "https://issuer.example.test/realm/$&/"

    page.current_window.resize_to(390, 900)
    assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")
    assert_no_selector ".translation_missing"
    page.save_screenshot(Rails.root.join("tmp/screenshots/russian-sso-390.png"))
  end

  test "Russian confirmation defaults remain text in the actual page" do
    sign_in_russian
    visit root_path
    page.execute_script(<<~JS)
      const dialog = document.querySelector("#confirm-dialog");
      const controller = window.Stimulus.getControllerForElementAndIdentifier(dialog, "confirm-dialog");
      controller.handleConfirm("true");
    JS
    within "#confirm-dialog" do
      assert_text "Вы уверены?"
      assert_text "Это действие нельзя отменить."
      assert_button "Подтвердить"
      assert_no_text "Are you sure?"
    end
  end

  test "import uploads preserve filenames and validate the formats declared by each real form" do
    user = sign_in_russian
    { "SureImport" => [ "данные-$&.NDJSON", "application/octet-stream" ],
      "TransactionImport" => [ "данные-$&", "text/csv" ] }.each do |type, (filename, mime)|
      import = user.family.imports.create!(type: type)
      visit import_upload_path(import)
      page.execute_script(<<~JS, filename, mime)
        const input = document.querySelector("[data-drag-and-drop-import-target='input']");
        input.form.addEventListener("submit", event => { event.preventDefault(); window.uploadRequested = true; });
        const transfer = new DataTransfer();
        transfer.items.add(new File(["{}"], arguments[0], {type: arguments[1]}));
        input.files = transfer.files;
        input.dispatchEvent(new Event("change", {bubbles: true}));
      JS
      assert_selector "[data-file-upload-target='fileName'] p", text: filename, exact_text: true
      page.execute_script(<<~JS)
        document.querySelector("[data-drag-and-drop-import-target='input']").form.dispatchEvent(new Event("turbo:submit-start"));
      JS
      assert_selector "[data-file-upload-target='fileName'] p", text: "Загрузка файла #{filename}…"

      page.execute_script(<<~JS, filename, mime)
        window.uploadRequested = false;
        const transfer = new DataTransfer();
        transfer.items.add(new File(["{}"], arguments[0], {type: arguments[1]}));
        document.dispatchEvent(new DragEvent("drop", {bubbles: true, dataTransfer: transfer}));
      JS
      assert_equal true, page.evaluate_script("window.uploadRequested")

      page.execute_script(<<~JS)
        window.uploadRequested = false;
        window.alert = message => { window.invalidUploadMessage = message; };
        const transfer = new DataTransfer();
        transfer.items.add(new File(["test"], "invalid.txt", {type: "text/plain"}));
        document.dispatchEvent(new DragEvent("drop", {bubbles: true, dataTransfer: transfer}));
      JS
      assert_equal false, page.evaluate_script("window.uploadRequested")
      assert_match(type == "SureImport" ? /Загрузите файл NDJSON или JSON/ : /CSV/, page.evaluate_script("window.invalidUploadMessage"))
      assert_no_selector ".translation_missing"
    end
  end

  private

    def sign_in_russian(user = users(:family_admin))
      user.update!(locale: "ru")
      sign_in user
      user
    end

    def select_attachment_files(count)
      page.execute_script(<<~JS, count)
        const input = document.querySelector("[data-attachment-upload-target='fileInput']");
        const transfer = new DataTransfer();
        for (let index = 0; index < arguments[0]; index++) {
          transfer.items.add(new File(["test"], `файл-$&-${index}.pdf`, { type: "application/pdf" }));
        }
        input.files = transfer.files;
        input.dispatchEvent(new Event("change", { bubbles: true }));
      JS
    end
end
