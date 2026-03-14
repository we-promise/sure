class ArchivedExportsController < ApplicationController
  skip_authentication

  def show
    export = ArchivedExport.find_by!(download_token: params[:token])

    if export.downloadable?
      redirect_to export.export_file, allow_other_host: true
    else
      head :gone
    end
  end
end
