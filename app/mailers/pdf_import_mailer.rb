class PdfImportMailer < ApplicationMailer
  def next_steps
    @user = params[:user]
    @pdf_import = params[:pdf_import]
    @document_uploaded_for_search = params[:document_uploaded_for_search] == true
    @import_url = import_url(@pdf_import)

    mail(
      to: @user.email,
      subject: t(".subject", product_name: product_name)
    )
  end
end
