require "spec_helper"
require "logger"
require "stringio"
require "tmpdir"

RSpec.describe Kitchen::Driver::Hetzner do
  let(:logged_output) { StringIO.new }
  let(:logger) { Logger.new(logged_output) }
  let(:platform_name) { "ubuntu-24.04" }
  let(:instance_name) { "default-ubuntu-2404" }
  let(:kitchen_root) { Dir.mktmpdir }
  let(:state) { {} }

  let(:connection) { instance_double("Kitchen::Transport::Ssh::Connection", wait_until_ready: true) }
  let(:transport) { double("transport", connection: connection) }

  let(:instance) do
    double(
      name: instance_name,
      logger: logger,
      to_str: "instance",
      platform: double(name: platform_name),
      transport: transport
    )
  end

  let(:config) { { hetzner_token: "sekret", kitchen_root: kitchen_root } }
  let(:driver) { described_class.new(config) }

  let(:api_client) { instance_double(Kitchen::Driver::Hcloud::Client) }

  before do
    allow_any_instance_of(described_class).to receive(:instance).and_return(instance)
    allow(driver).to receive(:client).and_return(api_client)
  end

  after { FileUtils.remove_entry(kitchen_root) if File.directory?(kitchen_root) }

  # Wires the client double for a successful create.
  def stub_successful_create(server: server_payload)
    allow(api_client).to receive(:create_ssh_key).and_return("id" => 7, "name" => "kitchen-abc")
    allow(api_client).to receive(:create_server)
      .and_return("server" => server, "action" => action_payload)
    allow(api_client).to receive(:wait_for_action).and_return(action_payload)
    allow(api_client).to receive(:server).and_return(server)
  end

  describe "configuration" do
    it "defaults to a current shared-vCPU server type" do
      expect(driver[:server_type]).to eq("cx22")
    end

    it "defaults to a Hetzner location" do
      expect(driver[:location]).to eq("fsn1")
    end

    it "defaults to root over SSH on port 22" do
      expect(driver[:username]).to eq("root")
      expect(driver[:port]).to eq(22)
    end

    it "defaults to the public API root" do
      expect(driver[:api_url]).to eq(Kitchen::Driver::Hcloud::Client::API_ROOT)
    end

    it "derives the image from the platform name" do
      expect(driver[:image]).to eq("ubuntu-24.04")
    end

    context "with a platform Hetzner names differently" do
      let(:platform_name) { "almalinux-9" }

      it "translates the platform name to a Hetzner slug" do
        expect(driver[:image]).to eq("alma-9")
      end
    end

    it "lets an explicit image win over the platform name" do
      driver = described_class.new(hetzner_token: "t", image: "my-snapshot-123")
      expect(driver[:image]).to eq("my-snapshot-123")
    end

    it "reads the token from HCLOUD_TOKEN" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("HCLOUD_TOKEN").and_return("from-env")
      expect(described_class.new({})[:hetzner_token]).to eq("from-env")
    end

    it "reports its version and API level for diagnostics" do
      expect(described_class.diagnose).to include(
        version: Kitchen::Driver::HETZNER_VERSION, api_version: 2
      )
    end
  end

  describe "#create" do
    before { stub_successful_create }

    it "records the server, address and connection details in state" do
      driver.create(state)

      expect(state[:server_id]).to eq(42)
      expect(state[:server_name]).to eq("kitchen-default-ubuntu-2404-abc123")
      expect(state[:hostname]).to eq("203.0.113.10")
      expect(state[:username]).to eq("root")
      expect(state[:port]).to eq(22)
    end

    it "waits for the transport to become ready" do
      expect(connection).to receive(:wait_until_ready)
      driver.create(state)
    end

    it "waits for the create action to finish before reading the address" do
      expect(api_client).to receive(:wait_for_action).with(action_payload, timeout: anything)
      driver.create(state)
    end

    it "is a no-op when a server already exists in state" do
      state[:server_id] = 99
      expect(api_client).not_to receive(:create_server)
      driver.create(state)
    end

    it "passes the configured server type, image and location through" do
      expect(api_client).to receive(:create_server).with(
        hash_including(server_type: "cx22", image: "ubuntu-24.04", location: "fsn1")
      ).and_return("server" => server_payload, "action" => action_payload)

      driver.create(state)
    end

    it "labels servers so that orphans can be found later" do
      expect(api_client).to receive(:create_server)
        .with(hash_including(labels: hash_including("created_by" => "test-kitchen",
          "kitchen_instance" => "default-ubuntu-2404")))
        .and_return("server" => server_payload, "action" => action_payload)

      driver.create(state)
    end

    it "passes cloud-init user data through when configured" do
      config[:user_data] = "#cloud-config\npackages:\n  - curl\n"
      expect(api_client).to receive(:create_server)
        .with(hash_including(user_data: "#cloud-config\npackages:\n  - curl\n"))
        .and_return("server" => server_payload, "action" => action_payload)

      driver.create(state)
    end

    it "falls back to a fresh lookup when the create response has no address yet" do
      stub_successful_create(server: server_payload("public_net" => { "ipv4" => nil }))
      allow(api_client).to receive(:server).and_return(server_payload)

      driver.create(state)
      expect(state[:hostname]).to eq("203.0.113.10")
    end

    it "fails clearly when the server never gets a public IPv4 address" do
      no_ip = server_payload("public_net" => { "ipv4" => nil })
      stub_successful_create(server: no_ip)
      allow(api_client).to receive(:server).and_return(no_ip)
      allow(api_client).to receive(:delete_server).and_return(true)
      allow(api_client).to receive(:delete_ssh_key).and_return(true)

      expect { driver.create(state) }
        .to raise_error(Kitchen::ActionFailed, /public IPv4/)
    end

    context "with a Windows platform" do
      let(:platform_name) { "windows-2022" }

      it "refuses before making any API call" do
        expect(api_client).not_to receive(:create_server)
        expect { driver.create(state) }
          .to raise_error(Kitchen::ActionFailed, /does not offer windows-2022 images/)
      end

      it "points at a driver that can do the job" do
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /kitchen-ec2/)
      end
    end

    describe "SSH keys" do
      it "generates and uploads a throwaway key when none is configured" do
        expect(api_client).to receive(:create_ssh_key)
          .with(hash_including(labels: { "created_by" => "test-kitchen" }))
          .and_return("id" => 7)

        driver.create(state)

        expect(state[:hetzner_ssh_key_id]).to eq(7)
        expect(state[:ssh_key]).to eq(File.join(kitchen_root, ".kitchen", "hetzner", "#{instance_name}.pem"))
        expect(File).to exist(state[:ssh_key])
      end

      it "writes the private key with owner-only permissions" do
        driver.create(state)
        expect(File.stat(state[:ssh_key]).mode & 0777).to eq(0600)
      end

      it "injects the uploaded key into the new server" do
        expect(api_client).to receive(:create_server)
          .with(hash_including(ssh_keys: [7]))
          .and_return("server" => server_payload, "action" => action_payload)

        driver.create(state)
      end

      it "uses configured keys without creating or recording one" do
        config[:ssh_keys] = %w{my-ci-key}
        expect(api_client).not_to receive(:create_ssh_key)
        expect(api_client).to receive(:create_server)
          .with(hash_including(ssh_keys: %w{my-ci-key}))
          .and_return("server" => server_payload, "action" => action_payload)

        driver.create(state)
        expect(state).not_to have_key(:hetzner_ssh_key_id)
      end
    end

    describe "when creation fails part way" do
      before do
        allow(api_client).to receive(:create_server)
          .and_raise(Kitchen::Driver::Hcloud::ApiError.new("image not found", code: "image_not_found"))
        allow(api_client).to receive(:delete_server).and_return(true)
        allow(api_client).to receive(:delete_ssh_key).and_return(true)
      end

      it "raises an ActionFailed carrying the API message" do
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /image not found/)
      end

      it "deletes the throwaway SSH key so it does not leak" do
        expect(api_client).to receive(:delete_ssh_key).with(7)
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed)
      end

      it "leaves no server id behind in state" do
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed)
        expect(state[:server_id]).to be_nil
      end

      it "does not mask the original error if cleanup also fails" do
        allow(api_client).to receive(:delete_ssh_key).and_raise(StandardError, "cleanup boom")
        expect { driver.create(state) }.to raise_error(Kitchen::ActionFailed, /image not found/)
      end
    end
  end

  describe "#destroy" do
    before do
      state[:server_id] = 42
      allow(api_client).to receive(:delete_server).and_return(true)
      allow(api_client).to receive(:delete_ssh_key).and_return(true)
    end

    it "deletes the server" do
      expect(api_client).to receive(:delete_server).with(42)
      driver.destroy(state)
    end

    it "clears connection details from state" do
      state[:hostname] = "203.0.113.10"
      state[:server_name] = "kitchen-abc"

      driver.destroy(state)

      expect(state).not_to have_key(:server_id)
      expect(state).not_to have_key(:hostname)
      expect(state).not_to have_key(:server_name)
    end

    it "does nothing when state has no server" do
      state.delete(:server_id)
      expect(api_client).not_to receive(:delete_server)
      driver.destroy(state)
    end

    it "tolerates a server that is already gone" do
      allow(api_client).to receive(:delete_server).and_return(false)
      expect { driver.destroy(state) }.not_to raise_error
    end

    it "raises an ActionFailed when the API rejects the delete" do
      allow(api_client).to receive(:delete_server)
        .and_raise(Kitchen::Driver::Hcloud::ApiError.new("server is locked"))

      expect { driver.destroy(state) }.to raise_error(Kitchen::ActionFailed, /locked/)
    end

    describe "ephemeral SSH keys" do
      let(:key_path) { File.join(kitchen_root, "id_rsa") }

      before do
        FileUtils.touch(key_path)
        state[:hetzner_ssh_key_id] = 7
        state[:ssh_key] = key_path
      end

      it "deletes the uploaded key" do
        expect(api_client).to receive(:delete_ssh_key).with(7)
        driver.destroy(state)
      end

      it "removes the private key from disk" do
        driver.destroy(state)
        expect(File).not_to exist(key_path)
      end

      it "clears the key from state" do
        driver.destroy(state)
        expect(state).not_to have_key(:hetzner_ssh_key_id)
        expect(state).not_to have_key(:ssh_key)
      end

      it "never deletes a key the user brought themselves" do
        state.delete(:hetzner_ssh_key_id)
        expect(api_client).not_to receive(:delete_ssh_key)
        driver.destroy(state)
        expect(File).to exist(key_path)
      end
    end
  end

  describe "#status" do
    it "reports unknown when nothing has been created" do
      expect(driver.status(state)).to include(live: nil, state: "unknown")
    end

    it "reports the server as live when it is running" do
      state[:server_id] = 42
      allow(api_client).to receive(:server).and_return(server_payload)

      expect(driver.status(state)).to include(live: true, state: "running", resource_id: 42)
    end

    it "reports a server that is not running as not live" do
      state[:server_id] = 42
      allow(api_client).to receive(:server).and_return(server_payload("status" => "off"))

      expect(driver.status(state)).to include(live: false, state: "off")
    end

    it "reports a vanished server as destroyed" do
      state[:server_id] = 42
      allow(api_client).to receive(:server).and_return(nil)

      expect(driver.status(state)).to include(live: false, state: "destroyed")
    end
  end

  describe "#doctor" do
    it "reports nothing when every labelled server has local state" do
      state[:server_id] = 42
      allow(api_client).to receive(:servers).and_return([server_payload("id" => 42)])

      expect(driver.doctor(state)).to be false
    end

    it "reports nothing when there are no labelled servers at all" do
      allow(api_client).to receive(:servers).and_return([])
      expect(driver.doctor(state)).to be false
    end

    it "flags servers with no local state as orphans" do
      allow(api_client).to receive(:servers)
        .and_return([server_payload("id" => 42), server_payload("id" => 99, "name" => "kitchen-orphan")])
      state[:server_id] = 42

      expect(driver.doctor(state)).to be true
      expect(logged_output.string).to include("kitchen-orphan")
      expect(logged_output.string).to include("hcloud server delete 99")
    end

    it "only queries servers this driver created" do
      expect(api_client).to receive(:servers)
        .with(label_selector: "created_by=test-kitchen").and_return([])

      driver.doctor(state)
    end

    it "treats servers recorded in other instances' state files as known" do
      FileUtils.mkdir_p(File.join(kitchen_root, ".kitchen"))
      File.write(File.join(kitchen_root, ".kitchen", "default-debian-12.yml"),
        YAML.dump(server_id: 99))
      allow(api_client).to receive(:servers).and_return([server_payload("id" => 99)])

      expect(driver.doctor(state)).to be false
    end

    it "ignores unreadable state files rather than crashing" do
      FileUtils.mkdir_p(File.join(kitchen_root, ".kitchen"))
      File.write(File.join(kitchen_root, ".kitchen", "broken.yml"), "\tnot: [valid")
      allow(api_client).to receive(:servers).and_return([])

      expect { driver.doctor(state) }.not_to raise_error
    end
  end

  describe "server naming" do
    it "suffixes the instance name so concurrent runs cannot collide" do
      first = driver.send(:unique_name, instance_name)
      second = driver.send(:unique_name, instance_name)

      expect(first).to start_with("default-ubuntu-2404-")
      expect(first).not_to eq(second)
    end

    it "replaces characters that are invalid in a hostname" do
      expect(driver.send(:unique_name, "My_Suite.Platform")).to match(/\Amy-suite-platform-[0-9a-f]{6}\z/)
    end

    it "keeps names within the Hetzner length limit" do
      expect(driver.send(:unique_name, "a" * 200).length).to eq(described_class::MAX_NAME_LENGTH)
    end

    it "falls back to a usable name when nothing survives sanitizing" do
      expect(driver.send(:unique_name, "___")).to start_with("kitchen-")
    end

    it "honours an explicitly configured server name" do
      config[:server_name] = "fixed-name"
      stub_successful_create
      expect(api_client).to receive(:create_server)
        .with(hash_including(name: "fixed-name"))
        .and_return("server" => server_payload, "action" => action_payload)

      driver.create(state)
    end
  end

  describe "labels" do
    it "sanitizes values that Hetzner would reject" do
      expect(driver.send(:sanitize_label, "feature/branch name")).to eq("feature-branch-name")
    end

    it "strips leading and trailing non-alphanumerics" do
      expect(driver.send(:sanitize_label, "--edge--")).to eq("edge")
    end

    it "truncates to the Hetzner limit" do
      expect(driver.send(:sanitize_label, "x" * 100).length).to eq(described_class::MAX_NAME_LENGTH)
    end

    it "merges user labels over the defaults" do
      config[:labels] = { "team" => "infra" }
      expect(driver.send(:server_labels)).to include(
        "created_by" => "test-kitchen", "team" => "infra"
      )
    end
  end
end
