module Celluloid
  # Trying to resume a dead task
  class DeadTaskError < StandardError; end

  # Tasks are interruptable/resumable execution contexts used to run methods
  class Task
    class TerminatedError < StandardError; end # kill a running fiber

    attr_reader   :type
    attr_accessor :status

    # Obtain the current task
    def self.current
      Fiber.current.task or raise "no task for this Fiber"
    end

    # Suspend the running task, deferring to the scheduler
    def self.suspend(status)
      task = Task.current
      task.status = status

      result = Fiber.yield
      raise TerminatedError, "task was terminated" if result == TerminatedError
      task.status = :running

      result
    end

    # Run the given block within a task
    def initialize(type)
      @type   = type
      @status = :new

      actor   = Thread.current[:actor]
      mailbox = Thread.current[:mailbox]

      @fiber = Fiber.new do
        @status = :running
        Thread.current[:actor]   = actor
        Thread.current[:mailbox] = mailbox
        Fiber.current.task = self
        actor.tasks << self

        begin
          yield
        rescue TerminatedError
          # Task was explicitly terminated
        ensure
          actor.tasks.delete self
        end
      end
    end

    # Resume a suspended task, giving it a value to return if needed
    def resume(value = nil)
      @fiber.resume value
      nil
    rescue FiberError
      raise DeadTaskError, "cannot resume a dead task"
    rescue RuntimeError => ex
      # These occur spuriously on 1.9.3 if we shut down an actor with running tasks
      return if ex.message == ""
      raise
    end

    # Terminate this task
    def terminate
      resume TerminatedError if @fiber.alive?
    rescue FiberError
      # If we're getting this the task should already be dead
    end

    # Is the current task still running?
    def running?; @fiber.alive?; end

    # Nicer string inspect for tasks
    def inspect
      "<Celluloid::Task:0x#{object_id.to_s(16)} @type=#{@type.inspect}, @status=#{@status.inspect}, @running=#{@fiber.alive?}>"
    end
  end

  # Tasks which propagate thread locals between fibers
  # TODO: This implementation probably uses more copypasta from Task than necessary
  # Refactor for less code and more DRY!
  class TaskWithThreadLocals < Task
    class << self
      # Suspend the running task, deferring to the scheduler
      def suspend(status)
        task = Task.current
        task.status = status

        result = Fiber.yield(extract_thread_locals)
        raise TerminatedError, "task was terminated" if result == TerminatedError
        task.status = :running

        result
      end

      def extract_thread_locals
        locals = {}
        Thread.current.keys.each do |k|
          # :__recursive_key__ is from MRI
          # :__catches__ is from rbx
          locals[k] = Thread.current[k] unless k == :__recursive_key__ || k == :__catches__
        end
        locals
      end
    end

    # Run the given block within a task
    def initialize(type)
      @type   = type
      @status = :new

      thread_locals = self.class.extract_thread_locals
      actor = Thread.current[:actor]

      @fiber = Fiber.new do
        @status = :running
        restore_thread_locals(thread_locals)

        Fiber.current.task = self
        actor.tasks << self

        begin
          yield
        rescue TerminatedError
          # Task was explicitly terminated
        ensure
          actor.tasks.delete self
        end

        self.class.extract_thread_locals
      end
    end

    # Resume a suspended task, giving it a value to return if needed
    def resume(value = nil)
      thread_locals = @fiber.resume value
      restore_thread_locals(thread_locals) if thread_locals

      nil
    rescue FiberError
      raise DeadTaskError, "cannot resume a dead task"
    rescue RuntimeError => ex
      # These occur spuriously on 1.9.3 if we shut down an actor with running tasks
      return if ex.message == ""
      raise
    end

  private

    def restore_thread_locals(locals)
      locals.each { |key, value| Thread.current[key] = value }
    end
  end
end
