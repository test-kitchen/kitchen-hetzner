require "spec_helper"
require "tmpdir"

RSpec.describe Kitchen::Driver::Hcloud::SshKey do
  # 2048 bits keeps the suite fast while exercising the same code paths.
  subject(:key) { described_class.generate(bits: 2048) }

  describe ".generate" do
    it "produces an RSA keypair of the requested size" do
      expect(key.rsa).to be_a(OpenSSL::PKey::RSA)
      expect(key.rsa.n.num_bits).to eq(2048)
    end

    it "produces a private key" do
      expect(key.rsa.private?).to be true
    end
  end

  describe "#openssh_public_key" do
    it "renders a key that ssh-keygen agrees with" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "id_rsa")
        key.write(path)

        expected = `ssh-keygen -y -f #{path} 2>/dev/null`.strip
        skip "ssh-keygen unavailable" unless expected.start_with?("ssh-rsa")

        # ssh-keygen emits no comment, so compare the algorithm and body only.
        expect(key.openssh_public_key(comment: "kitchen").split[0, 2]).to eq(expected.split[0, 2])
      end
    end

    it "starts with the ssh-rsa algorithm identifier" do
      expect(key.openssh_public_key).to start_with("ssh-rsa AAAAB3NzaC1yc2E")
    end

    it "appends a comment when one is given" do
      expect(key.openssh_public_key(comment: "kitchen-abc")).to end_with(" kitchen-abc")
    end

    it "omits the trailing space when no comment is given" do
      rendered = key.openssh_public_key
      expect(rendered.split.length).to eq(2)
      expect(rendered).not_to end_with(" ")
    end

    it "round-trips back to the same modulus" do
      blob = key.openssh_public_key.split[1].unpack1("m")
      parts = []
      offset = 0
      3.times do
        length = blob[offset, 4].unpack1("N")
        offset += 4
        parts << blob[offset, length]
        offset += length
      end

      expect(parts[0]).to eq("ssh-rsa")
      expect(OpenSSL::BN.new(parts[2], 2)).to eq(key.rsa.n)
    end
  end

  describe "#write" do
    it "writes a PEM private key readable by OpenSSL" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "nested", "id_rsa")
        expect(key.write(path)).to eq(path)

        reloaded = OpenSSL::PKey::RSA.new(File.read(path))
        expect(reloaded.n).to eq(key.rsa.n)
      end
    end

    it "creates parent directories" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "a", "b", "id_rsa")
        key.write(path)
        expect(File).to exist(path)
      end
    end

    it "restricts permissions to the owner so ssh will accept the key" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "id_rsa")
        key.write(path)
        expect(File.stat(path).mode & 0777).to eq(0600)
      end
    end
  end
end
