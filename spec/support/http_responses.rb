# WebMock response bodies for the Hetzner Cloud API.
module HttpResponses
  # Builds a successful JSON response.
  #
  # @param body [Hash] the payload to serialize
  # @return [Hash] a WebMock `to_return` hash
  def json(body)
    { status: 200, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
  end

  # Builds a Hetzner error response.
  #
  # @param status [Integer] the HTTP status to return
  # @param code [String] the Hetzner error code
  # @param message [String] the human-readable message
  # @return [Hash] a WebMock `to_return` hash
  def error_json(status, code, message)
    {
      status: status,
      body: JSON.generate("error" => { "code" => code, "message" => message }),
      headers: { "Content-Type" => "application/json" },
    }
  end
end
