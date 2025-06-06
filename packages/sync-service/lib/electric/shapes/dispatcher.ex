defmodule Electric.Shapes.Dispatcher do
  @moduledoc """
  Dispatches transactions and relations to consumers filtered using `Filter`
  and the consumer's shape.

  The essential behaviour is that the dispatcher only asks the producer for
  more demand once all relevant subscribers have processed the last message and
  asked for the next.

  This behaviour is subtly different from `GenStage.BroadcastDispatcher` in
  that events that don't match the consumer's selector do not generate demand.
  We only wait for the consumers who received the event to ack successful
  processing before forwarding demand onto the producer.

  This is not a generalised dispatcher, its behaviour is specialised to our
  requirements. Demand is always 1 -- consumers MUST only ever ask for a single
  message from the producer and the dispatcher MUST only ever receive
  1 message from the producer to dispatch.

  This can be done by subscribing with `max_demand: 1` or using manual demand
  and calling `GenStage.ask(producer, 1)`.
  """

  require Logger

  alias Electric.Shapes.Filter
  alias Electric.Shapes.Partitions
  alias Electric.Telemetry.OpenTelemetry

  defmodule State do
    defstruct [:waiting, :pending, :subscribers, :filter, :partitions, :pids]
  end

  @behaviour GenStage.Dispatcher

  @impl GenStage.Dispatcher

  def init(opts) do
    {:ok,
     %State{
       waiting: 0,
       pending: nil,
       subscribers: [],
       filter: Filter.new(opts),
       partitions: Partitions.new(opts),
       pids: MapSet.new()
     }}
  end

  @impl GenStage.Dispatcher
  def subscribe(opts, {pid, _ref} = from, %State{pids: pids} = state) do
    if MapSet.member?(pids, pid) do
      Logger.error(fn ->
        "#{inspect(pid)} is already registered with #{inspect(self())}. " <>
          "This subscription has been discarded."
      end)

      {:error, :already_subscribed}
    else
      shape = Keyword.fetch!(opts, :shape)

      demand = if state.subscribers == [], do: 1, else: 0

      subscribers = [{from, shape} | state.subscribers]

      partitions = Partitions.add_shape(state.partitions, from, shape)
      filter = Filter.add_shape(state.filter, from, shape)

      {:ok, demand,
       %State{
         state
         | subscribers: subscribers,
           filter: filter,
           partitions: partitions,
           pids: MapSet.put(state.pids, pid)
       }}
    end
  end

  @impl GenStage.Dispatcher
  def cancel({pid, _ref} = from, %State{waiting: waiting, pending: pending} = state) do
    if MapSet.member?(state.pids, pid) do
      subscribers = List.keydelete(state.subscribers, from, 0)

      filter = Filter.remove_shape(state.filter, from)
      partitions = Partitions.remove_shape(state.partitions, from)

      state = %{
        state
        | subscribers: subscribers,
          filter: filter,
          partitions: partitions,
          pids: MapSet.delete(state.pids, pid)
      }

      if pending && MapSet.member?(pending, from) do
        case waiting - 1 do
          0 ->
            # the only remaining unacked subscriber has cancelled, so we
            # return some demand
            {:ok, 1, %State{state | waiting: 0, pending: nil}}

          new_waiting ->
            {:ok, 0, %State{state | waiting: new_waiting, pending: MapSet.delete(pending, from)}}
        end
      else
        {:ok, 0, state}
      end
    else
      {:ok, 0, state}
    end
  end

  @impl GenStage.Dispatcher
  # consumers sending demand before we have produced a message just ignore as
  # we have already sent initial demand of 1 to the producer when the first
  # consumer subscribed.
  def ask(1, {_pid, _ref}, %State{waiting: 0, pending: nil} = state) do
    {:ok, 0, state}
  end

  def ask(1, {_pid, _ref}, %State{waiting: 1} = state) do
    {:ok, 1, %State{state | waiting: 0, pending: nil}}
  end

  def ask(1, from, %State{waiting: waiting, pending: pending} = state) when waiting > 1 do
    {:ok, 0, %State{state | waiting: waiting - 1, pending: MapSet.delete(pending, from)}}
  end

  @impl GenStage.Dispatcher
  # handle the no subscribers case here to make the real dispatch impl easier
  def dispatch([event], _length, %State{waiting: 0, subscribers: []} = state) do
    {:ok, [event], state}
  end

  def dispatch([event], _length, %State{waiting: 0, subscribers: subscribers} = state) do
    {partitions, event} =
      OpenTelemetry.timed_fun("partitions.handle_event.duration_µs", fn ->
        Partitions.handle_event(state.partitions, event)
      end)

    OpenTelemetry.timed_fun("dispatcher.dispatch.duration_µs", fn ->
      context = OpenTelemetry.get_current_context()

      {waiting, pending} =
        state.filter
        |> Filter.affected_shapes(event)
        |> Enum.reduce({0, MapSet.new()}, fn {pid, ref} = subscriber, {waiting, pending} ->
          Process.send(pid, {:"$gen_consumer", {self(), ref}, [{event, context}]}, [:noconnect])
          {waiting + 1, MapSet.put(pending, subscriber)}
        end)
        |> case do
          {0, _pending} ->
            # even though no subscriber wants the event, we still need to generate demand
            # so that we can complete the loop in the log collector
            [{subscriber, _selector} | _] = subscribers
            send(self(), {:"$gen_producer", subscriber, {:ask, 1}})
            {1, MapSet.new([subscriber])}

          {waiting, pending} ->
            {waiting, pending}
        end

      {:ok, [], %State{state | partitions: partitions, waiting: waiting, pending: pending}}
    end)
  end

  @impl GenStage.Dispatcher
  def info(msg, state) do
    send(self(), msg)
    {:ok, state}
  end
end
