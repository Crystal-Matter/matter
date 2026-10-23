require "../spec_helper"
require "../../src/matter/storage/cli"

module CliSpec
  include Matter::Storage

  def self.with_temp_dir(& : String ->) : Nil
    directory = File.join(Dir.tempdir, "matter-cli-spec-#{Random::Secure.hex(6)}")
    begin
      yield directory
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  def self.run(args : Array(String)) : {Int32, String, String}
    output = IO::Memory.new
    error = IO::Memory.new
    status = Matter::Storage::CLI.run(args, output, error)
    {status, output.to_s, error.to_s}
  end
end

describe Matter::Storage::CLI do
  describe "migrate" do
    it "copies between stores and reports counts" do
      CliSpec.with_temp_dir do |directory|
        yaml_path = File.join(directory, "old.yml")
        json_path = File.join(directory, "new.json")
        source = Matter::Storage::YamlFile.new(yaml_path).tap(&.open)
        source.write(Matter::Storage::Collections::FABRICS, "1", Matter::Storage::Document{"label" => "one"})
        source.write(Matter::Storage::Collections::FABRICS, "2", Matter::Storage::Document{"label" => "two"})
        source.write(Matter::Storage::Collections::SESSIONS, "s", Matter::Storage::Document{"counter" => 1_i64})
        source.close

        status, output, error = CliSpec.run(["migrate", "--from", "yaml:#{yaml_path}", "--to", "json:#{json_path}"])
        status.should eq(Matter::Storage::CLI::EXIT_OK)
        error.should be_empty
        output.should contain("fabrics: 2 documents")
        output.should contain("sessions: 1 document\n")
        output.should contain("Copied 3 documents")

        target = Matter::Storage::JsonFile.new(json_path).tap(&.open)
        target.read(Matter::Storage::Collections::FABRICS, "2").should eq(Matter::Storage::Document{"label" => "two"})
        target.close
      end
    end

    it "requires both --from and --to" do
      status, _, error = CliSpec.run(["migrate", "--from", "memory:"])
      status.should eq(Matter::Storage::CLI::EXIT_USAGE)
      error.should contain("needs --from and --to")
      error.should contain("Usage:")
    end

    it "reports storage errors" do
      status, _, error = CliSpec.run(["migrate", "--from", "memory:", "--to", "unregistered:x"])
      status.should eq(Matter::Storage::CLI::EXIT_FAILURE)
      error.should contain("Unknown storage URI scheme")
    end
  end

  describe "inspect" do
    it "prints collections, ids and redacted documents" do
      CliSpec.with_temp_dir do |directory|
        path = File.join(directory, "store.yml")
        store = Matter::Storage::YamlFile.new(path).tap(&.open)
        store.write(Matter::Storage::Collections::FABRICS, "1", Matter::Storage::Document{
          "label"       => "one",
          "ipk"         => "not really bytes",
          "root_cert"   => 5_i64,
          "public_key"  => Bytes[1, 2, 3],
          "challenge"   => nil,
          "secret_list" => ([1_i64] of Matter::Storage::Type).as(Matter::Storage::Type),
          "nested"      => Matter::Storage::Document{"api_key" => "k", "count" => 2_i64}.as(Matter::Storage::Type),
          "when"        => Time.utc(2026, 9, 10, 1, 2, 3),
        })
        store.close

        status, output, error = CliSpec.run(["inspect", "yaml:#{path}"])
        status.should eq(Matter::Storage::CLI::EXIT_OK)
        error.should be_empty
        output.should contain("yaml:#{path}: 2 collections\n")
        output.should contain("fabrics (1)\n  1\n")
        output.should contain("    label: \"one\"\n")
        output.should contain("    ipk: <redacted>\n")
        output.should contain("    root_cert: <redacted>\n")
        output.should contain("    public_key: <bytes 3>\n")
        output.should contain("    challenge: null\n")
        output.should contain("    secret_list: <redacted>\n")
        output.should contain("    nested: {api_key: <redacted>, count: 2}\n")
        output.should contain("    when: 2026-09-10T01:02:03.000000000Z\n")
        output.should contain("meta (1)\n  schema\n    version: 1\n")
        output.should_not contain("not really bytes")
      end
    end

    it "requires a store URI" do
      status, _, error = CliSpec.run(["inspect"])
      status.should eq(Matter::Storage::CLI::EXIT_USAGE)
      error.should contain("needs a store URI")
    end
  end

  it "prints usage without a command" do
    status, _, error = CliSpec.run([] of String)
    status.should eq(Matter::Storage::CLI::EXIT_USAGE)
    error.should contain("Usage: matter-storage")
  end

  it "prints help" do
    status, output, _ = CliSpec.run(["--help"])
    status.should eq(Matter::Storage::CLI::EXIT_OK)
    output.should contain("migrate")
    output.should contain("inspect")
  end

  it "rejects unknown options" do
    status, _, error = CliSpec.run(["inspect", "--bogus", "memory:"])
    status.should eq(Matter::Storage::CLI::EXIT_USAGE)
    error.should contain("Unknown option --bogus")
  end
end
