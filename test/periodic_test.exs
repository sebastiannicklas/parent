defmodule PeriodicTest do
  use ExUnit.Case, async: true
  import Periodic.Test
  import Periodic.TestHelper

  setup do
    observe(:test_job)
  end

  test "auto mode" do
    test_pid = self()
    Periodic.start_link(every: 1, run: fn -> send(test_pid, :started) end)
    assert_receive :started
    assert_receive :started
  end

  test "regular job execution" do
    scheduler = start_scheduler!()

    refute_periodic_event(:test_job, :started, %{scheduler: ^scheduler})
    tick(scheduler)
    assert_periodic_event(:test_job, :started, %{scheduler: ^scheduler, job: job})
    assert_receive {:started, ^job}

    refute_periodic_event(:test_job, :started, %{scheduler: ^scheduler})
    tick(scheduler)
    assert_periodic_event(:test_job, :started, %{scheduler: ^scheduler, job: job})
    assert_receive {:started, ^job}
  end

  test "finished telemetry event" do
    {scheduler, job} = start_job!()
    finish_job(job)

    assert_periodic_event(:test_job, :finished, %{scheduler: ^scheduler, job: ^job}, %{time: time})

    assert is_integer(time) and time > 0
  end

  describe "on_overlap" do
    test "ignore" do
      {scheduler, job} = start_job!(on_overlap: :ignore)

      tick(scheduler)
      assert_periodic_event(:test_job, :skipped, %{scheduler: ^scheduler, still_running: ^job})
      refute_periodic_event(:test_job, :started, %{scheduler: ^scheduler})

      finish_job(job)
      tick(scheduler)
      assert_periodic_event(:test_job, :started, %{scheduler: ^scheduler, job: job})
    end

    test "stop_previous" do
      {scheduler, job} = start_job!(on_overlap: :stop_previous)

      mref = Process.monitor(job)

      tick(scheduler)
      assert_receive({:DOWN, ^mref, :process, ^job, :killed})
      assert_periodic_event(:test_job, :stopped_previous, %{scheduler: ^scheduler, pid: ^job})
      assert_periodic_event(:test_job, :started, %{scheduler: ^scheduler})
    end
  end

  test "timeout" do
    {_scheduler, job} = start_job!(timeout: 1)
    mref = Process.monitor(job)
    assert_receive({:DOWN, ^mref, :process, ^job, :killed})
  end

  describe "initial_delay" do
    test "is by default equal to the interval" do
      scheduler = start_scheduler!(every: 100)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 100})
    end

    test "overrides the first tick interval" do
      scheduler = start_scheduler!(every: 100, initial_delay: 0)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 0})

      tick(scheduler)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 100})
    end
  end

  describe "delay_mode" do
    test "regular" do
      scheduler = start_scheduler!(delay_mode: :regular, every: 100)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 100})

      tick(scheduler)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 100})

      tick(scheduler)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 100})
    end

    test "shifted" do
      scheduler = start_scheduler!(delay_mode: :shifted, every: 100)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 100})

      tick(scheduler)
      assert_periodic_event(:test_job, :started, %{scheduler: ^scheduler, job: job})
      refute_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler})

      finish_job(job)
      assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler, in: 100})
    end
  end

  describe "job shutdown" do
    test "timeout when job doesn't trap exits" do
      {_scheduler, job} = start_job!(job_shutdown: 10, trap_exit?: false)
      mref = Process.monitor(job)
      stop_supervised(:test_job)
      assert_receive {:DOWN, ^mref, :process, ^job, :shutdown}
    end

    test "timeout when job traps exits" do
      {_scheduler, job} = start_job!(job_shutdown: 10, trap_exit?: true)
      mref = Process.monitor(job)
      stop_supervised(:test_job)
      assert_receive {:DOWN, ^mref, :process, ^job, :killed}
    end

    test "brutal_kill" do
      {_scheduler, job} = start_job!(job_shutdown: :brutal_kill, trap_exit?: true)
      mref = Process.monitor(job)
      stop_supervised(:test_job)
      assert_receive {:DOWN, ^mref, :process, ^job, :killed}
    end

    test "infinity" do
      {scheduler, job} = start_job!(job_shutdown: :infinity, trap_exit?: true)

      mref = Process.monitor(scheduler)

      # Invoking asynchronously because this code blocks. Since the code is invoked from another
      # process, we have to use GenServer.stop.
      Task.start_link(fn -> GenServer.stop(scheduler) end)

      refute_receive {:DOWN, ^mref, :process, ^scheduler, _}

      send(job, :finish)
      assert_receive {:DOWN, ^mref, :process, ^scheduler, _}
    end
  end

  test "registered name" do
    scheduler = start_scheduler!(name: :registered_name)
    assert Process.whereis(:registered_name) == scheduler
    assert_periodic_event(:test_job, :next_tick, %{scheduler: ^scheduler})
  end
end
