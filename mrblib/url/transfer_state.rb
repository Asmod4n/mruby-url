# mrblib/url/transfer_state.rb
#
# URL::TransferState — per-transfer accumulation of the response body and raw
# header lines for blocking requests. Internal plumbing.

class URL::TransferState
  attr_accessor :error_code
  attr_reader   :body, :raw_headers

  def initialize
    @body        = String.new
    @raw_headers = []
    @error_code  = 0
  end

end
