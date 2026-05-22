class ArchivedExportsController < ApplicationController
  skip_authentication

  def show
    export = ArchivedExport.find_by_download_token!(params[:token])

    if export.downloadable?
      redirect_to rails_blob_path(export.export_file, disposition: "attachment")
    else
      head :gone
    end
  end
end
