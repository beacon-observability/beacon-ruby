# frozen_string_literal: true

module Beacon
  module Security
    # Explicit installation after optional database clients are loaded.
    module Hooks
      module_function

      # Install once per loaded client; late client loads require another call.
      def install
        ::Kernel.prepend(KernelCalls) unless ::Kernel < KernelCalls
        ::Kernel.singleton_class.prepend(KernelSingletonCalls) unless ::Kernel.singleton_class < KernelSingletonCalls
        ::File.singleton_class.prepend(FileCalls) unless ::File.singleton_class < FileCalls
        ::Net::HTTP.prepend(HTTPCalls) if defined?(::Net::HTTP) && !(::Net::HTTP < HTTPCalls)
        ::PG::Connection.prepend(PGCalls) if defined?(::PG::Connection) && !(::PG::Connection < PGCalls)
        ::Mysql2::Client.prepend(MysqlCalls) if defined?(::Mysql2::Client) && !(::Mysql2::Client < MysqlCalls)
      end

      # Single strings may be shell scripts; argument arrays stay distinct.
      module KernelCalls
        private

        %i[system spawn].each do |method|
          define_method(method) do |*args, **kwargs|
            inputs = args.first.is_a?(Hash) ? args.drop(1) : args
            inputs.each_with_index do |value, index|
              role = if inputs.size == 1
                       'shell_script'
                     else
                       (index.zero? ? 'executable' : 'argument')
                     end
              rule = role == 'shell_script' ? 'command_injection' : 'command_execution'
              Security.observe(rule, value, function: "Kernel.#{method}", role: role)
            end
            super(*args, **kwargs)
          end
        end
      end

      KernelSingletonCalls = KernelCalls.dup
      KernelSingletonCalls.send(:public, :system, :spawn)

      # File class entry points only; IO and native extensions are not modeled.
      module FileCalls
        { read: 'read', binread: 'read', write: 'write', binwrite: 'write', delete: 'delete', unlink: 'delete' }.each do |method, operation|
          define_method(method) do |path, *args, **kwargs|
            paths = operation == 'delete' ? [path, *args] : [path]
            paths.each do |input|
              Security.observe('path_traversal', input, function: "File.#{method}", role: 'file_path', operation: operation, path_role: operation == 'read' ? 'source' : 'target')
            end
            super(path, *args, **kwargs)
          end
        end
      end

      # Observe destination and request input separately before network invocation.
      module HTTPCalls
        # Destination matching has no DNS or allowlist policy and stays unknown.
        def request(req, *args, &)
          Security.observe('ssrf', address, function: 'Net::HTTP.request', role: 'destination_address')
          Security.observe('http_request_input', req.path, function: 'Net::HTTP.request', role: 'path_or_query', input_part: 'path_or_query')
          super
        end
      end

      # Bound values are excluded from template observations.
      module PGCalls
        %i[exec exec_params prepare].each do |method|
          define_method(method) do |*args, **kwargs, &block|
            sql = method == :prepare ? args[1] : args[0]
            Security.observe('sql_injection', sql, function: "PG::Connection.#{method}", role: 'sql_template')
            super(*args, **kwargs, &block)
          end
        end
      end

      # Prepared statement execution is not a template source.
      module MysqlCalls
        %i[query prepare].each do |method|
          define_method(method) do |sql, *args, **kwargs, &block|
            Security.observe('sql_injection', sql, function: "Mysql2::Client.#{method}", role: 'sql_template')
            super(sql, *args, **kwargs, &block)
          end
        end
      end
    end
  end
end
