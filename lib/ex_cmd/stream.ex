defmodule ExCmd.Stream do
  @moduledoc """
  Defines a `ExCmd.Stream` struct returned by `ExCmd.stream!/2`.
  """

  alias ExCmd.Process
  alias ExCmd.Process.Error

  defmodule Sink do
    defstruct [:process]

    defimpl Collectable do
      def into(%{process: process} = stream) do
        collector_fun = fn
          :ok, {:cont, x} ->
            :ok = Process.write(process, x)

          :ok, :done ->
            :ok = Process.close_stdin(process)
            stream

          :ok, :halt ->
            :ok = Process.close_stdin(process)
        end

        {:ok, collector_fun}
      end
    end
  end

  defstruct [:process, :stream_opts]

  @default_opts [exit_timeout: :infinity]

  @type t :: %__MODULE__{}

  @doc false
  def __build__(cmd_with_args, opts) do
    {stream_opts, process_opts} = Keyword.split(opts, [:exit_timeout, :input])
    stream_opts = Keyword.merge(@default_opts, stream_opts)

    {:ok, process} = Process.start_link(cmd_with_args, process_opts)

    start_input_streamer(%Sink{process: process}, stream_opts[:input])
    %ExCmd.Stream{process: process, stream_opts: stream_opts}
  end

  @doc false
  defp start_input_streamer(sink, input) do
    cond do
      is_nil(input) ->
        :ok

      is_function(input, 1) ->
        spawn_link(fn ->
          input.(sink)
        end)

      Enumerable.impl_for(input) ->
        spawn_link(fn ->
          input
          |> Stream.into(sink)
          |> Stream.run()
        end)

      true ->
        raise ArgumentError,
          message: ":input must be either Enumerable or a function with arity 1"
    end
  end

  defimpl Enumerable do
    def reduce(%{process: process, stream_opts: stream_opts}, acc, fun) do
      start_fun = fn -> :ok end

      next_fun = fn :ok ->
        case Process.read(process) do
          {:ok, x} ->
            {[x], :ok}

          :eof ->
            {:halt, :normal}

          error ->
            raise Error, "Failed to read data from the command. error: #{inspect(error)}"
        end
      end

      after_fun = fn exit_type ->
        try do
          # always close stdin before stoping to give the command chance to exit properly
          Process.close_stdin(process)

          result = Process.await_exit(process, stream_opts[:exit_timeout])

          if exit_type == :normal do
            case result do
              {:ok, 0} ->
                :ok

              {:ok, status} ->
                raise Error, "command exited with status: #{status}"

              :timeout ->
                raise Error, "command fail to exit within timeout: #{stream_opts.exit_timeout}"
            end
          end
        after
          Process.stop(process)
        end
      end

      Stream.resource(start_fun, next_fun, after_fun).(acc, fun)
    end

    def count(_stream) do
      {:error, __MODULE__}
    end

    def member?(_stream, _term) do
      {:error, __MODULE__}
    end

    def slice(_stream) do
      {:error, __MODULE__}
    end
  end
end
