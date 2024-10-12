# frozen_string_literal: true

require 'nio'
require 'red-black-tree'
require 'resolv'

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
      @blocked = RedBlackTree.new
    end

    private

    def run
      while @waiting.any? || @blocked.any? || @runnable.min&.ready
        ready_monitors = @selector.select(next_timeout)
        ready_monitors&.each do |monitor|
          @waiting.delete! waiting_node = @waiting.search { |node| node.monitor == monitor }

          data = waiting_node.data
          data.vruns += 1
          data.timeout_time = nil
          data.monitor = nil

          @runnable << (RunnableNode.new data)
        end

        while timed_out_node = min_timeout_time_nodes.find { |node| node.timeout_time <= current_time }
          case timed_out_node
          when WaitingNode then @waiting
          when BlockedNode then @blocked
          end.delete! timed_out_node

          data = timed_out_node.data
          data.vruns += 1
          data.timeout_time = nil
          data.monitor = nil

          @runnable << (RunnableNode.new data)
        end

        while @runnable.min&.ready
          ready_node = @runnable.shift

          data = ready_node.data
          fiber = data.fiber
          data.ready = false

          @runnable << (ReadyNode.new data)

          fiber.resume
        end
      end
    end

    def next_timeout
      if min_timeout_time = min_timeout_time_nodes.filter_map { |node| node.data.timeout_time }.min
        [min_timeout_time - current_time, 0].max
      end
    end

    def min_timeout_time_nodes
      [@waiting.min, @blocked.min].compact
    end

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    module Implementation
      def address_resolve hostname
        Resolv.getaddresses hostname.sub /%.*/, ''
      end

      def block _blocker, timeout = nil
        fiber = Fiber.current
        timeout_time = current_time + timeout if timeout

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data = runnable_node.data
        data.timeout_time = timeout_time

        @blocked << blocked_node = (BlockedNode.new data)

        @fiber.transfer
      ensure
        @blocked.delete! blocked_node
      end

      def close
        run
      end

      def fiber &block
        fiber = Fiber.new &block
        vruns = 1

        @runnable << runnable_node = (RunnableNode.new (NodeData.new fiber:, vruns:))

        fiber.resume

        fiber
      ensure
        @runnable.delete! runnable_node
      end

      def io_pread io, buffer, from, length, offset
        fiber = Fiber.current
        timeout_time = current_time + io.timeout if io.timeout
        monitor = @selector.register io, :r

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data = runnable_node.data
        data.timeout_time = timeout_time
        data.monitor = monitor

        @waiting << waiting_node = (WaitingNode.new data)

        @fiber.transfer

        unless monitor.readable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become readable!"
        end

        buffer.pread io, from, length, offset
      ensure
        monitor.close
        @waiting.delete! waiting_node
      end

      def io_pwrite io, buffer, from, length, offset
        fiber = Fiber.current
        timeout_time = current_time + io.timeout if io.timeout
        monitor = @selector.register io, :w

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data = runnable_node.data
        data.timeout_time = timeout_time
        data.monitor = monitor

        @waiting << waiting_node = (WaitingNode.new data)

        @fiber.transfer

        unless monitor.writable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become writable!"
        end

        buffer.pwrite io, from, length, offset
      ensure
        monitor.close
        @waiting.delete! waiting_node
      end

      def io_read io, buffer, length, offset
        fiber = Fiber.current
        timeout_time = current_time + io.timeout if io.timeout
        monitor = @selector.register io, :r

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data = runnable_node.data
        data.timeout_time = timeout_time
        data.monitor = monitor

        @waiting << waiting_node = (WaitingNode.new data)

        @fiber.transfer

        unless monitor.readable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become readable!"
        end

        io.read_nonblock length, buffer, offset
      ensure
        monitor.close
        @waiting.delete! waiting_node
      end

      def io_select readables, writables, exceptables, timeout
        raise NotImplementedError
      end

      def io_wait io, events, timeout
        fiber = Fiber.current
        timeout_time = current_time + timeout if timeout
        monitor = @selector.register io, (events_readiness events)

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data = runnable_node.data
        data.timeout_time = timeout_time
        data.monitor = monitor

        @waiting << waiting_node = (WaitingNode.new data)

        @fiber.transfer
      ensure
        monitor.close
        @waiting.delete! waiting_node
      end

      private def events_readiness events
        "".tap do |readiness|
          readiness += "r" if (events & IO::READABLE).nonzero?
          readiness += "w" if (events & IO::WRITABLE).nonzero?
        end.to_sym
      end

      def io_write io, buffer, length, offset
        fiber = Fiber.current
        timeout_time = current_time + io.timeout if io.timeout
        monitor = @selector.register io, :w

        @runnable.delete! runnable_node = @runnable.search { |node| node.fiber == fiber }

        data = runnable_node.data
        data.timeout_time = timeout_time
        data.monitor = monitor

        @waiting << waiting_node = (WaitingNode.new data)

        @fiber.transfer

        unless monitor.writable?
          raise IO::TimeoutError, "Timeout (#{io.timeout}s) while waiting for IO to become writable!"
        end

        io.write_nonblock length, buffer, offset
      ensure
        monitor.close
        @waiting.delete! waiting_node
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

          data = blocked_node.data
          data.vruns += 1
          data.timeout_time = nil

          @runnable << (RunnableNode.new data)
        end
      end
    end

    self.include Implementation
  end
end
