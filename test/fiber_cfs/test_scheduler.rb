# frozen_string_literal: true

require "test_helper"

class FiberCFS::TestScheduler < Minitest::Test
  def test_new
    scheduler = FiberCFS::Scheduler.new
    assert_instance_of FiberCFS::Scheduler, scheduler
  end
end
