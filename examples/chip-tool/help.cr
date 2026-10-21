module ChipTool
  module Help
    extend self

    def render(error : String? = nil) : String
      io = IO::Memory.new
      if error
        io.puts "chip-tool: #{error}"
        io.puts
      end

      io.puts "Usage:"
      io.puts "  crystal run examples/chip-tool.cr -- <cluster|command-set> <command> [args...] [--storage-directory <dir>] [--timeout <seconds>]"
      io.puts "  Optional fabric selection: --fabric-id <id> [--root-public-key <hex>] [--controller-node-id <id>]"
      io.puts
      io.puts "Command Sets / Clusters:"

      Registry.command_index.each do |set_name, commands|
        io.puts "  #{set_name}"
        commands.each do |cmd|
          io.puts "    #{cmd.name.ljust(26)} #{cmd.description}"
        end
      end

      io.to_s
    end
  end
end
