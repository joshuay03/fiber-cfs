require 'benchmark'

def set_scheduler!
  # single thread: 5.438603666611016
  # multi-thread:
  require_relative 'lib/fiber-cfs'
  Fiber.set_scheduler FiberCFS::Scheduler.new

  # single thread: 5.451972666700992
  # multi-thread:
  # require 'async'
  # Fiber.set_scheduler Async::Scheduler.new
end

set_scheduler!

puts (3.times.map do
  Benchmark.measure do
    # Define a method to simulate more CPU-bound work
    def cpu_bound_work(id)
      # Perform a more intensive calculation with prime numbers
      sum = 0
      (1..100_000).each do |num|
        sum += num if prime?(num)
      end
      puts "CPU work #{id} done with sum of primes #{sum}\n"
    end

    # Check if a number is prime (CPU-bound)
    def prime?(num)
      return false if num < 2
      (2..Math.sqrt(num)).none? { |i| num % i == 0 }
    end

    # Define a method to simulate more varied I/O-bound work
    def io_bound_work(id, duration)
      # Randomly choose between reading and writing
      if duration.even?
        io_write_work(id, duration)
      else
        io_read_work(id, duration)
      end
    end

    # Simulate a file write operation
    def io_write_work(id, duration)
      sleep(duration)
      file_name = "dummy_write_#{id}.txt"
      File.open(file_name, 'w') { |f| f.write("Simulated write I/O work for #{id}") }
      File.delete(file_name) if File.exist?(file_name)
      puts "Write IO work #{id} done after sleeping for #{duration} seconds and writing to file\n"
    end

    # Simulate a file read operation
    def io_read_work(id, duration)
      file_name = "dummy_read_#{id}.txt"
      # Create the file first with some content
      File.open(file_name, 'w') { |f| f.write("Content for #{id} to simulate read") }

      sleep(duration)

      # Simulate reading the file
      content = File.read(file_name)
      puts "Read IO work #{id} done after sleeping for #{duration} seconds and reading: #{content}\n"

      # Clean up the file
      File.delete(file_name) if File.exist?(file_name)
    end

    # A method to run a list of fibers within a single thread
    def run_fibers_in_thread(fiber_count, thread_id)
      # Create CPU-bound fibers
      (fiber_count / 2).times do |i|
        Fiber.schedule do
          cpu_bound_work("CPU Fiber #{thread_id}-#{Fiber.current.object_id}")
        end
      end

      # Create I/O-bound fibers
      (fiber_count / 2).times do |i|
        Fiber.schedule do
          duration = i.even? ? 2 : 5
          io_bound_work("IO Fiber #{thread_id}-#{Fiber.current.object_id}", duration)
        end
      end
    end

    # Create two threads, each managing 5 fibers (10 fibers in total)
    thread1 = Thread.new { set_scheduler!; run_fibers_in_thread(4, 1) }
    # thread2 = Thread.new { set_scheduler!; run_fibers_in_thread(4, 2) }

    # Wait for both threads to finish
    thread1.join
    # thread2.join
  end.real
end.sum / 3)
