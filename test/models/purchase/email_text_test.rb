require "test_helper"

class Purchase::EmailTextTest < ActiveSupport::TestCase
  test "reads a forwarded HTML order as text with table rows on their own lines" do
    result = text_for("amazon_manual_forward.eml")

    assert_includes result.text, "Order Total: $249.99"
    assert_includes result.text, "HEPA filter for XR-200 vacuum | HomeParts LLC | 2 | $79.98"
    assert_includes result.text, "View or manage order"
    refute_includes result.text, "<td"
    refute_includes result.text, "alert(1)"
    refute_includes result.text, "color:red"
    refute_includes result.text, "https://www.amazon.com/your-orders"
    assert_not result.truncated
  end

  test "lifts the forwarded message's headers to the top" do
    text = text_for("amazon_manual_forward.eml").text

    assert_match(/\AOriginal-From: Amazon.com <auto-confirm@amazon.com>\n/, text)
    assert_includes text, "Original-Date: Thu, Nov 12, 2026 at 6:42 PM"
    assert_includes text, "Original-Subject: Your Amazon.com order #112-1234567-1234567"
    assert_includes text, "Received-Date: Sun, 22 Nov 2026 09:15:00 -0500"
  end

  test "an automatically forwarded order uses its own headers" do
    text = text_for("amazon_auto_forward.eml").text

    assert_includes text, "Original-From: \"Amazon.com\" <auto-confirm@amazon.com>"
    assert_includes text, "Original-Date: Thu, 12 Nov 2026 18:42:00 -0500"
    assert_includes text, "Order #112-1234567-1234567"
  end

  test "reads an order forwarded as an attachment" do
    text = text_for("forward_as_attachment.eml").text

    assert_includes text, "Order Total: $249.99"
    assert_includes text, "Original-From: \"Amazon.com\" <auto-confirm@amazon.com>"
  end

  test "the shop's domain comes from the forwarded block, not the person who forwarded it" do
    assert_equal "amazon.com", text_for("amazon_manual_forward.eml").original_from_domain
  end

  test "an automatically forwarded order gives its own sender's domain" do
    assert_equal "amazon.com", text_for("amazon_auto_forward.eml").original_from_domain
  end

  test "an order forwarded as an attachment gives the attached message's sender domain" do
    assert_equal "amazon.com", text_for("forward_as_attachment.eml").original_from_domain
  end

  test "a shop sending from a subdomain gives its registrable domain" do
    assert_equal "allegro.pl", domain_from("Allegro <powiadomienia@powiadomienia.allegro.pl>")
    assert_equal "amazon.co.uk", domain_from("x@mail.amazon.co.uk")
  end

  test "an unparseable sender gives no domain" do
    assert_nil domain_from("Allegro")
  end

  test "an attached receipt photo is sent along, as JPEG" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Receipt", body: "")
    mail.add_file(filename: "receipt.png", content: noise_png)

    files = Purchase::EmailText.new(mail).call.files

    assert_equal 1, files.size
    assert_equal "image/jpeg", files.first[:content_type]
    assert_equal "receipt.jpg", files.first[:filename]
    assert files.first[:data].start_with?("\xFF\xD8".b)
  end

  test "a photo labelled image/jpg by the mail app is sent too" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Receipt", body: "")
    mail.attachments["receipt.jpg"] = { mime_type: "image/jpg", content: Vips::Image.gaussnoise(300, 300).cast(:uchar).jpegsave_buffer(Q: 95) }

    assert_equal [ "image/jpeg" ], Purchase::EmailText.new(mail).call.files.map { _1[:content_type] }
  end

  test "a PDF is sent as it is" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Invoice", body: "Thank you for your order")
    mail.add_file(filename: "invoice.pdf", content: fake_pdf)

    files = Purchase::EmailText.new(mail).call.files

    assert_equal [ [ "application/pdf", "invoice.pdf" ] ], files.map { [ _1[:content_type], _1[:filename] ] }
  end

  # Logos are small images; a shop's e-receipt PDF can be smaller than the image minimum.
  test "a small PDF is still sent" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Receipt", body: "Receipt")
    mail.add_file(filename: "e-receipt.pdf", content: build_pdf(padding: 2_000))

    assert_equal [ "e-receipt.pdf" ], Purchase::EmailText.new(mail).call.files.map { _1[:filename] }
  end

  test "small images, other file types and oversized files are not sent" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Order", body: "Order")
    mail.add_file(filename: "logo.png", content: Vips::Image.black(10, 10).pngsave_buffer)
    mail.add_file(filename: "notes.txt", content: "x" * 30_000)
    mail.add_file(filename: "huge.pdf", content: fake_pdf(11.megabytes))

    assert_empty Purchase::EmailText.new(mail).call.files
  end

  test "at most five files are sent" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Order", body: "Order")
    6.times { |index| mail.add_file(filename: "page#{index}.pdf", content: fake_pdf(25_000 + index)) }

    assert_equal 5, Purchase::EmailText.new(mail).call.files.size
  end

  test "long PDFs such as terms and conditions, and PDFs that can't be opened, are not sent" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Order", body: "Order")
    mail.add_file(filename: "terms.pdf", content: build_pdf(pages: 6))
    mail.add_file(filename: "broken.pdf", content: "%PDF-1.4\n" + ("x" * 25_000))

    assert_empty Purchase::EmailText.new(mail).call.files
  end

  test "attached files come before images embedded in the email's layout" do
    mail = Mail.new(from: "bob@bobdylan.com", subject: "Order")
    mail.html_part = Mail::Part.new(content_type: "text/html; charset=UTF-8", body: "<p>Thanks for your order</p>")
    5.times { |index| mail.attachments.inline["product#{index}.png"] = Vips::Image.gaussnoise(300 + index, 300).cast(:uchar).pngsave_buffer }
    mail.add_file(filename: "invoice.pdf", content: fake_pdf)

    files = Purchase::EmailText.new(mail).call.files

    assert_equal 5, files.size
    assert_equal "invoice.pdf", files.first[:filename]
  end

  test "files inside an order forwarded as an attachment are found" do
    inner = Mail.new(from: "shop@example.com", subject: "Your receipt", body: "Receipt attached")
    inner.add_file(filename: "receipt.pdf", content: fake_pdf)
    outer = Mail.new(from: "bob@bobdylan.com", subject: "Fwd: Your receipt", body: "")
    outer.attachments["forwarded.eml"] = { mime_type: "message/rfc822", content: inner.to_s }

    assert_equal [ "receipt.pdf" ], Purchase::EmailText.new(outer).call.files.map { _1[:filename] }
  end

  test "decodes ISO-8859-2" do
    text = text_for("iso_8859_2.eml").text

    assert_includes text, "Ship to: Łódź, Żółta St. 5"
    assert_includes text, "Order Total: $12.50"
  end

  test "falls back to the plain text part" do
    assert_includes text_for("not_an_order.eml").text, "Your package has shipped"
  end

  test "recognizes a Polish forward marker" do
    mail = Mail.new(body: "---------- Wiadomość przekazana dalej ---------\nOd: Sklep <shop@example.com>\nData: 12.11.2026\nTemat: Zamówienie\n\nDo zapłaty: 10,00 zł")

    text = Purchase::EmailText.new(mail).call.text

    assert_match(/\AOriginal-From: Sklep <shop@example.com>\nOriginal-Date: 12.11.2026\nOriginal-Subject: Zamówienie/, text)
  end

  test "an order forwarded twice inline takes the shop's headers from the innermost forward" do
    body = <<~TEXT
      FYI

      ---------- Forwarded message ---------
      From: Alice <alice@family.example>
      Date: Fri, 13 Nov 2026
      Subject: Fwd: Your order

      ---------- Forwarded message ---------
      From: Shop <orders@shop.example>
      Date: Thu, 12 Nov 2026
      Subject: Your order

      Total: $10.00
    TEXT

    result = Purchase::EmailText.new(Mail.new(body:)).call

    assert_match(/\AOriginal-From: Shop <orders@shop.example>\nOriginal-Date: Thu, 12 Nov 2026\nOriginal-Subject: Your order/, result.text)
    assert_equal "shop.example", result.original_from_domain
  end

  test "a forward marker quoted without headers after it doesn't hide the real forward" do
    body = "---------- Forwarded message ---------\nFrom: Shop <orders@shop.example>\nSubject: Your order\n\n" \
           "Reply above this line\n---------- Forwarded message ---------\nnothing here\n"

    assert_equal "shop.example", Purchase::EmailText.new(Mail.new(body:)).call.original_from_domain
  end

  test "truncates long emails and says so" do
    mail = Mail.new(body: "x" * 50_000)

    result = Purchase::EmailText.new(mail).call

    assert_equal Purchase::EmailText::MAX_CHARS, result.text.length
    assert result.truncated
    assert_equal 50_000, result.input_chars
  end

  private
    def noise_png
      Vips::Image.gaussnoise(300, 300).cast(:uchar).pngsave_buffer
    end

    def fake_pdf(size = 25_000)
      build_pdf(padding: size)
    end

    def domain_from(from)
      Purchase::EmailText.new(Mail.new(from:, subject: "Order", body: "Order total 10.00")).call.original_from_domain
    end

    def text_for(name)
      Purchase::EmailText.new(Mail.new(file_fixture("purchase_emails/#{name}").binread)).call
    end
end
