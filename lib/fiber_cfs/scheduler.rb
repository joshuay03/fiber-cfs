# frozen_string_literal: true

require 'nio'
require 'red-black-tree'
require 'resolv'

require_relative 'node_data'
require_relative 'runnable_node'
require_relative 'waiting_node'
require_relative 'blocked_node'

module FiberCFS
  class Scheduler
    def initialize
      @fiber = Fiber.current

      @selector = NIO::Selector.new

      @mutex = Thread::Mutex.new

      @runnable = RedBlackTree.new
      @waiting = RedBlackTree.new
      @waiting_ready = {}
      @blocked = RedBlackTree.new
    end

    private

    def run
      while @waiting.any? || @blocked.min&.timeout_time || @runnable.min&.ready
        if @waiting.any?
          ready_monitors = @selector.select next_timeout
          ready_monitors&.each do |monitor|
            if (deregister_or_update monitor).closed?
              @waiting.select { |node| node.monitor.io == monitor.io }.each do |waiting_node|
                @waiting.delete! waiting_node

                data_attrs = waiting_node.data.to_h
                data_attrs.merge! vruns: (data_attrs[:vruns] + 1), ready: true, timeout_time: nil, monitor: nil
                @runnable << (RunnableNode.new NodeData.new **data_attrs)
              end
            end
          end
        end

        while timed_out_node = min_timeout_time_nodes.find { |node| node.timeout_time && node.timeout_time <= current_time }
          if timed_out_node.monitor
            deregister_or_update timed_out_node.monitor, force: true
            @waiting.delete! timed_out_node
          else
            @blocked.delete! timed_out_node
          end

          data_attrs = timed_out_node.data.to_h
          data_attrs.merge! vruns: (data_attrs[:vruns] + 1), ready: true, timeout_time: nil, monitor: nil
          @runnable << (RunnableNode.new NodeData.new **data_attrs)
        end

        while @runnable.min&.ready
          ready_node = @runnable.shift
          fiber = ready_node.fiber

          data_attrs = ready_node.data.to_h
          data_attrs.merge! ready: false
          @runnable << (RunnableNode.new NodeData.new **data_attrs)

          fiber.transfer if fiber.alive?
        end
      end
    end

    def next_timeout
      if min_timeout_time = min_timeout_time_nodes.filter_map(&:timeout_time).min
        [min_timeout_time - current_time, 0].max
      end
    end

    def min_timeout_time_nodes
      [@waiting.min, @blocked.min].compact
    end

    def current_time
      Process.clock_gettime Process::CLOCK_MONOTONIC
    end

    def register_or_update io, interests
      if @selector.registered? io
        @waiting.search { |node| node.monitor.io == io }.monitor.tap do |current_monitor|
          current_monitor.add_interest interests
        end
      else
        @selector.register io, interests
      end
    end

    def deregister_or_update monitor, force: false
      if force || monitor.readiness == monitor.interests
        @selector.deregister monitor.io
      else
        interest_to_remove = monitor.readiness == :r ? :w : :r
        monitor.tap do |current_monitor|
          current_monitor.remove_interest interest_to_remove
        end
      end
    end

    def events_interests events
      "".tap do |interests|
        interests << "r" if (events & IO::READABLE).nonzero?
        interests << "w" if (events & IO::WRITABLE).nonzero?
      end.to_sym
    end

    def blocking &block
      Fiber.blocking &block
    end

    module Implementation
      def address_resolve hostname
        Resolv.getaddresses hostname.sub /%.*/, ''
      end

      def block _blocker, timeout = nil
        fiber = Fiber.current
        timeout_time = current_time + timeout if timeout

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data_attrs = runnable_node.data.to_h
        data_attrs.merge! timeout_time: timeout_time
        @blocked << (BlockedNode.new NodeData.new **data_attrs)

        @fiber.transfer
      end

      def close
        run
      end

      def fiber &block
        fiber = Fiber.new &block
        vruns = 1

        @runnable << (RunnableNode.new NodeData.new fiber:, vruns:)

        fiber.transfer

        fiber
      end

      def io_pread io, buffer, from, length, offset
        fiber = Fiber.current

        return 0 if @waiting_ready.delete fiber

        timeout_time = current_time + io.timeout if io.timeout
        monitor = register_or_update io, :r

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data_attrs = runnable_node.data.to_h
        data_attrs.merge! timeout_time: timeout_time, monitor: monitor
        @waiting << waiting_node = (WaitingNode.new NodeData.new **data_attrs)

        @fiber.transfer

        unless monitor.readable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become readable!"
        end

        @waiting_ready[fiber] = true

        blocking { buffer.pread io, from, length, offset }
      end

      def io_pwrite io, buffer, from, length, offset
        fiber = Fiber.current

        return 0 if @waiting_ready.delete fiber

        timeout_time = current_time + io.timeout if io.timeout
        monitor = register_or_update io, :w

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data_attrs = runnable_node.data.to_h
        data_attrs.merge! timeout_time: timeout_time, monitor: monitor
        @waiting << waiting_node = (WaitingNode.new NodeData.new **data_attrs)

        @fiber.transfer

        unless monitor.writable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become writable!"
        end

        @waiting_ready[fiber] = true

        blocking { buffer.pwrite io, from, length, offset }
      end

      def io_read io, buffer, length, offset
        fiber = Fiber.current

        return 0 if @waiting_ready.delete fiber

        timeout_time = current_time + io.timeout if io.timeout
        monitor = register_or_update io, :r

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data_attrs = runnable_node.data.to_h
        data_attrs.merge! timeout_time: timeout_time, monitor: monitor
        @waiting << waiting_node = (WaitingNode.new NodeData.new **data_attrs)

        @fiber.transfer

        unless monitor.readable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become readable!"
        end

        @waiting_ready[fiber] = true

        blocking { buffer.read io, length, offset }
      end

      def io_select readables, writables, exceptables, timeout
        raise NotImplementedError
      end

      def io_wait io, events, timeout
        fiber = Fiber.current
        timeout_time = current_time + timeout if timeout
        monitor = register_or_update events_interests events

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data_attrs = runnable_node.data.to_h
        data_attrs.merge! timeout_time: timeout_time, monitor: monitor
        @waiting << waiting_node = (WaitingNode.new NodeData.new **data_attrs)

        @fiber.transfer
      end

      def io_write io, buffer, length, offset
        fiber = Fiber.current

        return 0 if @waiting_ready.delete fiber

        timeout_time = current_time + io.timeout if io.timeout
        monitor = register_or_update io, :w

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data_attrs = runnable_node.data.to_h
        data_attrs.merge! timeout_time: timeout_time, monitor: monitor
        @waiting << waiting_node = (WaitingNode.new NodeData.new **data_attrs)

        @fiber.transfer

        unless monitor.writable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become writable!"
        end

        @waiting_ready[fiber] = true

        blocking { buffer.write io, length, offset }
      end

      def kernel_sleep duration = nil
        block :sleep, duration
      end

      def process_wait pid, flags
        Thread.new { Process::Status.wait pid, flags }.value
      end

      def timeout_after duration, exception_class, *exception_arguments, &block
        raise NotImplementedError
      end

      def unblock _blocker, fiber
        @mutex.synchronize do
          @blocked.delete! blocked_node = @blocked.search { |node| node.fiber == fiber }

          data_attrs = blocked_node.data.to_h
          data_attrs.merge! vruns: (data_attrs[:vruns] + 1), ready: true, timeout_time: nil
          @runnable << (RunnableNode.new NodeData.new **data_attrs)
        end
      end
    end

    self.include Implementation
  end
end
