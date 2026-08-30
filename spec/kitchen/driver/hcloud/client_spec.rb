require "spec_helper"

RSpec.describe Kitchen::Driver::Hcloud::Client do
  let(:api_root) { "https://api.hetzner.cloud/v1" }
  let(:slept) { [] }
  let(:sleeper) { ->(seconds) { slept << seconds } }
  let(:client) { described_class.new(token: "sekret", api_root: api_root, sleeper: sleeper) }

  def json(body)
    { status: 200, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }
  end

  def error_json(status, code, message)
    {
      status: status,
      body: JSON.generate("error" => { "code" => code, "message" => message }),
      headers: { "Content-Type" => "application/json" },
    }
  end

  describe "#initialize" do
    it "rejects a missing token" do
      expect { described_class.new(token: nil) }.to raise_error(ArgumentError, /token is required/)
      expect { described_class.new(token: "") }.to raise_error(ArgumentError, /token is required/)
    end

    it "defaults to the public API root" do
      expect(described_class.new(token: "x").api_root).to eq(described_class::API_ROOT)
    end
  end

  describe "authentication" do
    it "sends the token as a bearer header" do
      stub = stub_request(:get, "#{api_root}/servers/42")
        .with(headers: { "Authorization" => "Bearer sekret" })
        .to_return(json("server" => server_payload))

      client.server(42)
      expect(stub).to have_been_requested
    end

    it "identifies itself with a versioned user agent" do
      stub = stub_request(:get, "#{api_root}/servers/42")
        .with(headers: { "User-Agent" => "kitchen-hetzner/#{Kitchen::Driver::HETZNER_VERSION}" })
        .to_return(json("server" => server_payload))

      client.server(42)
      expect(stub).to have_been_requested
    end

    it "explains how to fix a 401 rather than leaking a bare HTTP error" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(401, "unauthorized", "unable to authenticate"))

      expect { client.server(42) }.to raise_error(
        Kitchen::Driver::Hcloud::ApiError, /HCLOUD_TOKEN/
      )
    end

    it "tags the 401 error with its code and status" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(401, "unauthorized", "unable to authenticate"))

      client.server(42)
    rescue Kitchen::Driver::Hcloud::ApiError => e
      expect(e.code).to eq("unauthorized")
      expect(e.status).to eq(401)
    end
  end

  describe "#create_server" do
    let(:response) { json("server" => server_payload, "action" => action_payload) }

    it "posts the required attributes" do
      stub = stub_request(:post, "#{api_root}/servers")
        .with(body: hash_including(
          "name" => "kitchen-abc",
          "server_type" => "cx22",
          "image" => "ubuntu-24.04",
          "location" => "fsn1",
          "start_after_create" => true
        ))
        .to_return(response)

      client.create_server(name: "kitchen-abc", server_type: "cx22", image: "ubuntu-24.04", location: "fsn1")
      expect(stub).to have_been_requested
    end

    it "returns the server and action" do
      stub_request(:post, "#{api_root}/servers").to_return(response)

      result = client.create_server(name: "kitchen-abc", server_type: "cx22", image: "ubuntu-24.04")
      expect(result["server"]["id"]).to eq(42)
      expect(result["action"]["command"]).to eq("create_server")
    end

    it "includes optional attributes only when they have content" do
      stub = stub_request(:post, "#{api_root}/servers")
        .with(body: hash_including(
          "ssh_keys" => [7],
          "user_data" => "#cloud-config",
          "labels" => { "created_by" => "test-kitchen" }
        ))
        .to_return(response)

      client.create_server(
        name: "kitchen-abc", server_type: "cx22", image: "ubuntu-24.04",
        ssh_keys: [7], user_data: "#cloud-config", labels: { "created_by" => "test-kitchen" }
      )
      expect(stub).to have_been_requested
    end

    it "omits empty optional attributes entirely" do
      stub_request(:post, "#{api_root}/servers").to_return(response)

      client.create_server(
        name: "kitchen-abc", server_type: "cx22", image: "ubuntu-24.04",
        ssh_keys: [], user_data: "", labels: {}, location: nil
      )

      expect(a_request(:post, "#{api_root}/servers").with { |req|
        body = JSON.parse(req.body)
        !body.key?("ssh_keys") && !body.key?("user_data") &&
          !body.key?("labels") && !body.key?("location")
      }).to have_been_made
    end

    it "surfaces a uniqueness conflict with the API's own message" do
      stub_request(:post, "#{api_root}/servers")
        .to_return(error_json(409, "uniqueness_error", "server name is already used"))

      expect { client.create_server(name: "dupe", server_type: "cx22", image: "ubuntu-24.04") }
        .to raise_error(Kitchen::Driver::Hcloud::ApiError, /server name is already used/)
    end
  end

  describe "#server" do
    it "returns the server hash" do
      stub_request(:get, "#{api_root}/servers/42").to_return(json("server" => server_payload))
      expect(client.server(42)["id"]).to eq(42)
    end

    it "returns nil when the server is gone rather than raising" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(404, "not_found", "server not found"))

      expect(client.server(42)).to be_nil
    end

    it "still raises for errors that are not a missing server" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(403, "forbidden", "nope"))

      expect { client.server(42) }.to raise_error(Kitchen::Driver::Hcloud::ApiError, /nope/)
    end
  end

  describe "#delete_server" do
    it "reports true when it deleted the server" do
      stub_request(:delete, "#{api_root}/servers/42").to_return(status: 204, body: "")
      expect(client.delete_server(42)).to be true
    end

    it "treats an already-deleted server as success" do
      stub_request(:delete, "#{api_root}/servers/42")
        .to_return(error_json(404, "not_found", "server not found"))

      expect(client.delete_server(42)).to be false
    end

    it "raises for any other failure" do
      stub_request(:delete, "#{api_root}/servers/42")
        .to_return(error_json(423, "locked", "server is locked"))

      expect { client.delete_server(42) }.to raise_error(Kitchen::Driver::Hcloud::ApiError, /locked/)
    end
  end

  describe "#servers" do
    it "passes a label selector through" do
      stub = stub_request(:get, "#{api_root}/servers")
        .with(query: hash_including("label_selector" => "created_by=test-kitchen"))
        .to_return(json("servers" => [], "meta" => { "pagination" => { "next_page" => nil } }))

      client.servers(label_selector: "created_by=test-kitchen")
      expect(stub).to have_been_requested
    end

    it "follows pagination to the end" do
      stub_request(:get, "#{api_root}/servers").with(query: hash_including("page" => "1"))
        .to_return(json("servers" => [server_payload("id" => 1)],
          "meta" => { "pagination" => { "next_page" => 2 } }))
      stub_request(:get, "#{api_root}/servers").with(query: hash_including("page" => "2"))
        .to_return(json("servers" => [server_payload("id" => 2)],
          "meta" => { "pagination" => { "next_page" => nil } }))

      expect(client.servers.map { |s| s["id"] }).to eq([1, 2])
    end

    it "stops rather than looping when the API does not advance the page" do
      stub_request(:get, "#{api_root}/servers?page=1&per_page=50")
        .to_return(json("servers" => [server_payload],
          "meta" => { "pagination" => { "next_page" => 1 } }))

      expect(client.servers.length).to eq(1)
    end

    it "returns an empty array when there are no servers" do
      stub_request(:get, "#{api_root}/servers").with(query: hash_including({}))
        .to_return(json("servers" => [], "meta" => { "pagination" => { "next_page" => nil } }))

      expect(client.servers).to eq([])
    end
  end

  describe "SSH keys" do
    it "creates a key with its public half and labels" do
      stub = stub_request(:post, "#{api_root}/ssh_keys")
        .with(body: hash_including("name" => "kitchen-abc", "public_key" => "ssh-rsa AAAA"))
        .to_return(json("ssh_key" => { "id" => 7, "name" => "kitchen-abc" }))

      expect(client.create_ssh_key(name: "kitchen-abc", public_key: "ssh-rsa AAAA")["id"]).to eq(7)
      expect(stub).to have_been_requested
    end

    it "deletes a key" do
      stub_request(:delete, "#{api_root}/ssh_keys/7").to_return(status: 204, body: "")
      expect(client.delete_ssh_key(7)).to be true
    end

    it "treats an already-deleted key as success" do
      stub_request(:delete, "#{api_root}/ssh_keys/7")
        .to_return(error_json(404, "not_found", "ssh key not found"))

      expect(client.delete_ssh_key(7)).to be false
    end
  end

  describe "#wait_for_action" do
    it "returns immediately when the action already succeeded" do
      expect(client.wait_for_action(action_payload)).to eq(action_payload)
      expect(slept).to be_empty
    end

    it "returns nil input unchanged" do
      expect(client.wait_for_action(nil)).to be_nil
    end

    it "polls until the action succeeds" do
      stub_request(:get, "#{api_root}/actions/1001")
        .to_return(json("action" => action_payload("status" => "running")),
          json("action" => action_payload("status" => "success")))

      result = client.wait_for_action(action_payload("status" => "running"), interval: 3)
      expect(result["status"]).to eq("success")
      expect(slept).to eq([3, 3])
    end

    it "raises with the API's failure message when the action errors" do
      stub_request(:get, "#{api_root}/actions/1001")
        .to_return(json("action" => action_payload(
          "status" => "error",
          "error" => { "code" => "image_not_found", "message" => "image not found" }
        )))

      expect { client.wait_for_action(action_payload("status" => "running")) }
        .to raise_error(Kitchen::Driver::Hcloud::ApiError, /image not found/)
    end

    it "raises a timeout rather than polling forever" do
      expect { client.wait_for_action(action_payload("status" => "running"), timeout: 0) }
        .to raise_error(Kitchen::Driver::Hcloud::ApiError, /Timed out after 0s/)
    end

    it "tags a timeout with an action_timeout code" do
      client.wait_for_action(action_payload("status" => "running"), timeout: 0)
    rescue Kitchen::Driver::Hcloud::ApiError => e
      expect(e.code).to eq("action_timeout")
    end
  end

  describe "retry behaviour" do
    it "retries a rate limit and then succeeds" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(429, "rate_limit_exceeded", "slow down"),
          json("server" => server_payload))

      expect(client.server(42)["id"]).to eq(42)
      expect(slept.length).to eq(1)
    end

    it "honours a Retry-After header" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return({ status: 429, headers: { "Retry-After" => "7" }, body: "{}" },
          json("server" => server_payload))

      client.server(42)
      expect(slept).to eq([7])
    end

    it "backs off exponentially when no Retry-After is given" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(503, "unavailable", "nope"),
          error_json(503, "unavailable", "nope"),
          error_json(503, "unavailable", "nope"),
          json("server" => server_payload))

      client.server(42)
      expect(slept).to eq([1, 2, 4])
    end

    it "gives up after the retry budget is spent" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(500, "internal", "boom"))

      limited = described_class.new(token: "t", api_root: api_root, max_retries: 2, sleeper: sleeper)
      expect { limited.server(42) }.to raise_error(Kitchen::Driver::Hcloud::ApiError, /boom/)
      expect(slept.length).to eq(2)
    end

    it "does not retry a client error such as 404" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_return(error_json(404, "not_found", "gone"))

      client.server(42)
      expect(slept).to be_empty
    end

    it "retries a dropped connection" do
      stub_request(:get, "#{api_root}/servers/42")
        .to_raise(Errno::ECONNRESET).then
        .to_return(json("server" => server_payload))

      expect(client.server(42)["id"]).to eq(42)
      expect(slept.length).to eq(1)
    end

    it "converts an unrecoverable network failure into an ApiError" do
      stub_request(:get, "#{api_root}/servers/42").to_raise(SocketError.new("no dns"))

      limited = described_class.new(token: "t", api_root: api_root, max_retries: 1, sleeper: sleeper)
      expect { limited.server(42) }
        .to raise_error(Kitchen::Driver::Hcloud::ApiError, /SocketError.*no dns/)
    end

    # Anything missing from RETRIABLE_EXCEPTIONS does not merely skip the
    # retry -- it escapes as a raw exception rather than an ApiError, and the
    # driver reports an unexpected crash instead of an action failure.
    {
      "a TLS handshake reset" => OpenSSL::SSL::SSLError.new("read server hello A"),
      "an unroutable network" => Errno::ENETUNREACH.new("api.hetzner.cloud"),
      "a broken pipe" => Errno::EPIPE.new("api.hetzner.cloud"),
      "a truncated response" => EOFError.new("end of file reached"),
      "a malformed status line" => Net::HTTPBadResponse.new("wrong status line"),
      "an open timeout" => Net::OpenTimeout.new("execution expired"),
      "a read timeout" => Net::ReadTimeout.new("execution expired"),
    }.each do |description, error|
      it "retries #{description}" do
        stub_request(:get, "#{api_root}/servers/42")
          .to_raise(error).then
          .to_return(json("server" => server_payload))

        expect(client.server(42)["id"]).to eq(42)
        expect(slept.length).to eq(1)
      end

      it "reports #{description} as an ApiError once the budget is spent" do
        stub_request(:get, "#{api_root}/servers/42").to_raise(error)

        limited = described_class.new(token: "t", api_root: api_root, max_retries: 1, sleeper: sleeper)
        expect { limited.server(42) }
          .to raise_error(Kitchen::Driver::Hcloud::ApiError, /Hetzner API request failed/)
      end
    end
  end

  describe "response parsing" do
    it "tolerates an empty body on a successful delete" do
      stub_request(:delete, "#{api_root}/servers/42").to_return(status: 204, body: "")
      expect(client.delete_server(42)).to be true
    end

    it "tolerates a malformed body rather than raising a JSON error" do
      stub_request(:get, "#{api_root}/servers/42").to_return(status: 200, body: "not json")
      expect(client.server(42)).to be_nil
    end

    it "falls back to the HTTP status when the error body has no message" do
      stub_request(:get, "#{api_root}/servers/42").to_return(status: 418, body: "")
      expect { client.server(42) }.to raise_error(Kitchen::Driver::Hcloud::ApiError, /HTTP 418/)
    end
  end
end
