require "expect"
require "timeout"

module RiakTestServer
  class Error < StandardError; end

  def self.setup(options={})
    @server.stop if @server
    @server = Server.new(options)

    @server.setup
    @server.start
    @server.check
    @server.clear
  end

  def self.clear
    @server.clear
  end

  class Server
    attr_reader :repository, :tag
    def initialize(options)
      @force_restart = (options[:force_restart] || false)
      @container_host = (options[:container_host] || "docker")
      @container_name = (options[:container_name] || "riak_test_server")
      @http_port = (options[:http_port] || "8098")
      @pb_port = (options[:pb_port] || "8087")
      @repository = (options[:docker_repository] || "ntalbott/riak_test_server")
      @tag = (options[:docker_tag] || "latest")
      @docker_bin = (options[:docker_bin] || "docker")
    end

    def start
      if docker("ps -a") =~ /\b#{@container_name}\b/
        return unless @force_restart
        stop
        docker "rm #{@container_name}"
      end

      docker %W(
        run
        --name #{@container_name}
        --detach=true
        --interactive=true
        --publish=#{@http_port}:8098
        --publish=#{@pb_port}:8087
        #{@repository}:#{@tag}
      ).join(" "), 5
    end

    def stop
      @console_io.close if @console_io
      docker "stop #{@container_name}", 15
    end

    def setup
      unless docker("images", 5) =~ /#{repository}\s+#{tag}/
        docker "pull #{repository}:#{tag}", 60
      end
    end

    def clear
      result = console("{riak_kv_memory_backend:reset(), boom}.").chomp.strip
      raise "Unable to reset backend (#{result})" unless result == "{ok,boom}"
    end

    def check
      retries = 20
      loop do
        result = console("riak_kv_console:vnode_status([]).")
        break if result.split(/^VNode: \w+$/i).size >= 4 # at least 3 vnodes are available

        raise "vnodes not starting in time" if retries == 0
        retries -= 1
        sleep 1
      end
    end

    private

    def docker(command, timeout=1)
      full_command = "#{@docker_bin} #{command}"
      Timeout.timeout(timeout) do
        `#{full_command} 2>&1`.tap do |output|
          raise "#{full_command} failed: #{output}" unless $?.exitstatus == 0
        end
      end
    rescue Timeout::Error
      raise RiakTestServer::Error, "Timed out running `#{full_command}` after #{timeout} seconds; is your Docker host running?"
    end

    PROMPT = /\(riak@[\w\.]+\)(\d+)>\s*/
    def console(command)
      raise "Command not terminated with a `.`: #{command}" unless command =~ /\.\s*\z/
      attach do |io|
        io.puts(command)
        response = io.expect(PROMPT, 10)
        if response
          PROMPT.match(response.first).pre_match
        else
          raise "Prompt not returned after sending #{command} to Riak console"
        end
      end
    end

    def attach
      unless @console_io
        @console_io = IO.popen([@docker_bin, "attach", @container_name], "r+", err: :out).tap{|io| io.sync = true}
        @console_io.puts("ok.")
        unless @console_io.expect(PROMPT, 10)
          raise "Unable to get a prompt on the console"
        end
      end

      yield(@console_io)
    end
  end
end
