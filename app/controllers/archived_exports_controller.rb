class ArchivedExportsController < ApplicationController
  include ActiveStorage::Streaming

  skip_authentication

  # The archive's family is gone, so the token holder has no session for the
  # blob routes; the token is the only credential and the file is sent here.
  def show
    export = ArchivedExport.find_by_download_token!(params[:token])

    if export.downloadable?
      send_blob_stream export.export_file.blob, disposition: :attachment
    else
      head :gone
    end
  end
end
