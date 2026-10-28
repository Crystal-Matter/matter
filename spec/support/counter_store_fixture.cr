require "tempfile"
require "../../src/matter/controller/state_store"
require "../../src/matter/storage/yaml_file"

module Matter
  module Spec
    # A separate durable file for each counter-lease example. A Memory backend
    # cannot prove that a reserved high watermark survives a process restart.
    class CounterStoreFixture
      getter store : Controller::StateStore
      getter path : String

      def initialize
        @path = File.join(Dir.tempdir, "matter-counter-lease-#{Random::Secure.hex(8)}.yml")
        @store = Controller::StateStore.new(Storage::YamlFile.new(@path))
      end

      def close : Nil
        @store.backend.close
        File.delete?(@path)
        File.delete?("#{@path}.counter.lock")
      end
    end
  end
end
