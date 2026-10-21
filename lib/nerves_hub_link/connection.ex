# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Connection do
  @moduledoc """
  The device's one websocket connection to NervesHub.

  A Phoenix socket connection carries any number of channels - the topics a
  client joins, which here are `device`, `console` and `extensions` - and this
  owns the connection itself: the upgrade, the framing, the refs that pair a
  reply with what it answers, the heartbeats, and the joins of each channel
  over it.

  This is a data structure, not a process. The process that owns it passes it
  the messages it receives and acts on the events it gets back:

      {:ok, connection} = Connection.connect(Connection.new(opts))

      # in handle_info/2
      case Connection.handle_transport(connection, message) do
        {:ok, connection, events} -> Enum.reduce(events, connection, &handle_event/2)
        :unknown -> # not ours, handle it yourself
      end

  Keeping the connection in the caller's process rather than one of its own is
  deliberate. A device has one connection and one state machine over it, and
  the process boundary in between costs more than it pays for: it turns a push
  into a cross-process call that can exit its caller, it hides the connection's
  death from the thing that depends on it, and it puts the `Mint.HTTP` struct
  somewhere the owner has to go and read out of another process's state.

  ## Events

  `handle_transport/2` returns the events its message produced, in the order
  they happened. See `t:event/0`.

  ## Failing to send

  `join/3`, `push/4` and `send_heartbeat/1` return `{:error, reason, connection}`
  when a message cannot be sent. A write that fails has taken the connection
  with it, so check `connected?/1` on the returned connection: when it is false
  the caller should run whatever it does on `{:disconnected, reason}`, because
  no such event will arrive separately.
  """

  alias Mint.WebSocket.UpgradeFailureError
  alias NervesHubLink.Backoff
  alias NervesHubLink.Connection.Message

  require Logger

  # Heartbeats are not part of any topic, so Phoenix gives them their own.
  @heartbeat_topic "phoenix"

  @type t :: %__MODULE__{
          uri: URI.t(),
          headers: [{String.t(), String.t()}],
          serializer: module(),
          mint_opts: keyword(),
          extensions: [term()],
          upgrade_timeout_msec: non_neg_integer(),
          reconnect_after_msec: [non_neg_integer()],
          rejoin_after_msec: [non_neg_integer()],
          conn: Mint.HTTP.t() | nil,
          websocket: Mint.WebSocket.t() | nil,
          request_ref: Mint.Types.request_ref() | nil,
          upgrade_status: Mint.Types.status() | nil,
          upgrade_headers: Mint.Types.headers() | nil,
          upgrade_data: [binary()],
          upgrade_timer: reference() | nil,
          heartbeat_ref: String.t() | nil,
          status: :closed | :connecting | :connected,
          ref: non_neg_integer(),
          reconnect_count: non_neg_integer(),
          joins: %{optional(String.t()) => join()}
        }

  @typep join :: %{
           ref: String.t(),
           params: term(),
           status: :requested | :joined | :closed,
           rejoin_count: non_neg_integer()
         }

  @typedoc """
  Something that happened on the connection.

    * `:connected` - the websocket upgrade succeeded. Topics can be joined.
    * `{:joined, topic, response}` - the server accepted a join, answering
      with `response`.
    * `{:join_failed, topic, reason}` - the server refused a join.
    * `{:topic_closed, topic, reason}` - the server closed a joined topic,
      usually because the connection process crashed. The connection is still up.
    * `{:topic_left, topic}` - the server closed a topic normally.
    * `{:message, topic, event, payload}` - the server sent a message.
    * `{:reply, ref, reply}` - the server replied to the push sent with `ref`.
    * `{:disconnected, reason}` - the connection is gone.
  """
  @type event ::
          :connected
          | {:joined, topic :: String.t(), response :: term()}
          | {:join_failed, topic :: String.t(), reason :: term()}
          | {:topic_closed, topic :: String.t(), reason :: term()}
          | {:topic_left, topic :: String.t()}
          | {:message, topic :: String.t(), event :: String.t(), payload :: term()}
          | {:reply, ref :: String.t(), reply :: reply()}
          | {:disconnected, reason :: term()}

  @typedoc """
  A server's answer to a push.

  An empty response collapses to the bare atom. A status other than `ok` or
  `error` keeps the string the server sent.
  """
  @type reply :: :ok | :error | {:ok, term()} | {:error, term()} | {String.t(), term()}

  defstruct [
    :uri,
    :serializer,
    :conn,
    :websocket,
    :request_ref,
    :upgrade_status,
    :upgrade_headers,
    :upgrade_timer,
    :heartbeat_ref,
    headers: [],
    mint_opts: [protocols: [:http1]],
    extensions: [],
    upgrade_timeout_msec: 10_000,
    reconnect_after_msec: [1_000],
    rejoin_after_msec: [5_000],
    upgrade_data: [],
    status: :closed,
    ref: 0,
    reconnect_count: 0,
    joins: %{}
  ]

  @doc """
  Build a connection.

  Required options are `:uri` (whose `vsn` query parameter has to name the
  protocol version `:serializer` implements) and `:serializer`. The rest -
  `:headers`, `:mint_opts`, `:extensions`, `:upgrade_timeout_msec`,
  `:reconnect_after_msec` and `:rejoin_after_msec` - take the defaults in
  `t:t/0`.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    {uri, opts} = Keyword.pop!(opts, :uri)
    {serializer, opts} = Keyword.pop!(opts, :serializer)

    struct!(%__MODULE__{uri: uri, serializer: serializer}, opts)
  end

  @doc """
  Open the connection and ask for the websocket upgrade.

  Returns as soon as the request is sent; `:connected` arrives through
  `handle_transport/2` once the server has answered it. Must be called from
  the process that will receive the connection's messages.
  """
  @spec connect(t()) :: {:ok, t()} | {:error, reason :: term(), t()}
  def connect(%__MODULE__{} = connection) do
    uri = connection.uri

    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme(uri), uri.host, uri.port, connection.mint_opts),
         {:ok, conn, request_ref} <-
           Mint.WebSocket.upgrade(ws_scheme(uri), conn, path(uri), connection.headers,
             extensions: connection.extensions
           ) do
      {:ok,
       %{
         connection
         | conn: conn,
           request_ref: request_ref,
           status: :connecting,
           upgrade_timer: schedule_upgrade_timeout(connection, request_ref)
       }}
    else
      # `Mint.HTTP.connect/4` reports a failure to open the connection with
      # nothing to close; the upgrade reports one with a connection to clean up.
      {:error, reason} ->
        {:error, reason, reset(connection)}

      {:error, conn, reason} ->
        _ = Mint.HTTP.close(conn)
        {:error, reason, reset(connection)}
    end
  end

  @doc """
  Point the connection at a URL, with the headers to connect with.

  Both are settled per attempt rather than once, because both can change
  between attempts: a redirect moves the URL, and a signature in a header has
  to be made close to the moment it is sent or the server will have aged it
  out by the time it arrives.
  """
  @spec put_endpoint(t(), URI.t(), [{String.t(), String.t()}]) :: t()
  def put_endpoint(%__MODULE__{} = connection, %URI{} = uri, headers) when is_list(headers) do
    %{connection | uri: uri, headers: headers}
  end

  @doc """
  Replace the delays `reconnect_delay/1` works through.

  How long to wait is the owner's to decide and can change while running, but
  where in the list we are belongs with the connection, so it stays here and
  is left alone by this.
  """
  @spec put_reconnect_after_msec(t(), [non_neg_integer()]) :: t()
  def put_reconnect_after_msec(%__MODULE__{} = connection, [_ | _] = delays) do
    %{connection | reconnect_after_msec: delays}
  end

  def put_reconnect_after_msec(%__MODULE__{} = connection, _delays), do: connection

  @doc """
  Close the connection.

  Produces no `{:disconnected, reason}` event: the caller asked for this, so
  it already knows.
  """
  @spec close(t()) :: t()
  def close(%__MODULE__{} = connection) do
    _ = if connection.conn, do: Mint.HTTP.close(connection.conn)

    reset(connection)
  end

  @doc """
  Ask to join a topic.

  A topic that is already joined, or whose join is still unanswered, is left
  alone. `{:joined, topic, response}` or `{:join_failed, topic, reason}`
  arrives through `handle_transport/2`.
  """
  @spec join(t(), String.t(), term()) :: {:ok, t()} | {:error, reason :: term(), t()}
  def join(%__MODULE__{} = connection, topic, params \\ %{}) when is_binary(topic) do
    cond do
      not connected?(connection) ->
        {:error, :not_connected, connection}

      join_status(connection, topic) in [:requested, :joined] ->
        {:ok, connection}

      true ->
        send_join(connection, topic, params)
    end
  end

  @doc """
  Ask to join a topic again, with the parameters it was joined with before.

  Returns `{:error, :never_joined, connection}` for a topic that has not been
  joined, since there are no parameters to repeat.
  """
  @spec rejoin(t(), String.t()) :: {:ok, t()} | {:error, reason :: term(), t()}
  def rejoin(%__MODULE__{} = connection, topic) when is_binary(topic) do
    case Map.fetch(connection.joins, topic) do
      {:ok, %{params: params}} -> join(connection, topic, params)
      :error -> {:error, :never_joined, connection}
    end
  end

  @doc """
  Send a message on a joined topic.

  The returned ref is what a later `{:reply, ref, reply}` event will carry.
  """
  @spec push(t(), String.t(), String.t(), term()) ::
          {:ok, String.t(), t()} | {:error, reason :: term(), t()}
  def push(%__MODULE__{} = connection, topic, event, payload)
      when is_binary(topic) and is_binary(event) do
    cond do
      not connected?(connection) ->
        {:error, :not_connected, connection}

      not joined?(connection, topic) ->
        {:error, :not_joined, connection}

      true ->
        {ref, connection} = next_ref(connection)

        message = %Message{
          topic: topic,
          event: event,
          payload: payload,
          ref: ref,
          join_ref: connection.joins[topic].ref
        }

        case send_message(connection, message) do
          {:ok, connection} -> {:ok, ref, connection}
          {:error, reason, connection} -> {:error, reason, connection}
        end
    end
  end

  @doc """
  Send a heartbeat.

  Returns `{:error, :heartbeat_timeout, connection}`, with the connection closed,
  when the previous heartbeat has not been answered. That is the point of
  sending them: an idle TCP connection can be dead for a long time without
  either end noticing, and an unanswered heartbeat is how this one finds out.
  """
  @spec send_heartbeat(t()) :: {:ok, t()} | {:error, reason :: term(), t()}
  def send_heartbeat(%__MODULE__{heartbeat_ref: ref} = connection) when is_binary(ref) do
    {:error, :heartbeat_timeout, close(connection)}
  end

  def send_heartbeat(%__MODULE__{} = connection) do
    if connected?(connection) do
      {ref, connection} = next_ref(connection)

      message = %Message{topic: @heartbeat_topic, event: "heartbeat", payload: %{}, ref: ref}

      case send_message(connection, message) do
        {:ok, connection} -> {:ok, %{connection | heartbeat_ref: ref}}
        {:error, reason, connection} -> {:error, reason, connection}
      end
    else
      {:error, :not_connected, connection}
    end
  end

  @doc """
  Handle a message the owning process received.

  Returns `:unknown` for a message that has nothing to do with this
  connection, so the caller can go on and handle its own.
  """
  @spec handle_transport(t(), term()) :: {:ok, t(), [event()]} | :unknown
  def handle_transport(connection, message)

  # A timer from an earlier connection attempt carries that attempt's ref, so
  # it is ignored rather than taken for this one's.
  def handle_transport(
        %__MODULE__{request_ref: ref} = connection,
        {:connection_upgrade_timeout, ref}
      )
      when not is_nil(ref) do
    {:ok, close(connection), [{:disconnected, :upgrade_timeout}]}
  end

  def handle_transport(%__MODULE__{conn: nil}, _message), do: :unknown

  def handle_transport(%__MODULE__{} = connection, message) do
    case Mint.WebSocket.stream(connection.conn, message) do
      {:ok, conn, responses} ->
        {connection, events} = handle_responses(%{connection | conn: conn}, responses, [])
        {:ok, connection, events}

      {:error, conn, reason, _responses} ->
        connection = close(%{connection | conn: conn})
        {:ok, connection, [{:disconnected, transport_reason(reason)}]}

      :unknown ->
        :unknown
    end
  end

  @doc "Whether the websocket upgrade has completed and messages can be sent."
  @spec connected?(t()) :: boolean()
  def connected?(%__MODULE__{status: status}), do: status == :connected

  @doc "Whether a topic has been joined."
  @spec joined?(t(), String.t()) :: boolean()
  def joined?(%__MODULE__{} = connection, topic), do: join_status(connection, topic) == :joined

  @doc "How far a topic's join has got, or `nil` for one never joined."
  @spec join_status(t(), String.t()) :: :requested | :joined | :closed | nil
  def join_status(%__MODULE__{joins: joins}, topic) do
    case joins do
      %{^topic => %{status: status}} -> status
      _ -> nil
    end
  end

  @doc """
  The underlying socket, for asking which network interface it is using.

  `nil` until the connection is open.
  """
  @spec mint_socket(t()) :: term() | nil
  def mint_socket(%__MODULE__{conn: nil}), do: nil
  def mint_socket(%__MODULE__{conn: conn}), do: Mint.HTTP.get_socket(conn)

  @doc """
  How long to wait before connecting again, and the connection to carry on with.

  Each call moves one step along `:reconnect_after_msec`. Connecting
  successfully starts again from the beginning.
  """
  @spec reconnect_delay(t()) :: {non_neg_integer(), t()}
  def reconnect_delay(%__MODULE__{} = connection) do
    delay = Backoff.at(connection.reconnect_after_msec, connection.reconnect_count)

    {delay, %{connection | reconnect_count: connection.reconnect_count + 1}}
  end

  @doc """
  How long to wait before joining a topic again, and the connection to carry on with.

  Each call moves one step along `:rejoin_after_msec`. Joining successfully
  starts that topic again from the beginning.
  """
  @spec rejoin_delay(t(), String.t()) :: {non_neg_integer(), t()}
  def rejoin_delay(%__MODULE__{} = connection, topic) do
    count =
      case connection.joins do
        %{^topic => %{rejoin_count: count}} -> count
        _ -> 0
      end

    delay = Backoff.at(connection.rejoin_after_msec, count)

    {delay, update_join(connection, topic, &%{&1 | rejoin_count: count + 1})}
  end

  ## Sending

  defp send_join(connection, topic, params) do
    {ref, connection} = next_ref(connection)

    message = %Message{
      topic: topic,
      event: "phx_join",
      payload: params,
      ref: ref,
      join_ref: ref
    }

    case send_message(connection, message) do
      {:ok, connection} ->
        join = %{
          ref: ref,
          params: params,
          status: :requested,
          rejoin_count: rejoin_count(connection, topic)
        }

        {:ok, %{connection | joins: Map.put(connection.joins, topic, join)}}

      {:error, reason, connection} ->
        {:error, reason, connection}
    end
  end

  defp send_message(connection, message) do
    case encode(connection, message) do
      {:ok, frame} -> send_frame(connection, frame)
      {:error, reason} -> {:error, reason, connection}
    end
  end

  # A payload that cannot be encoded is this device's own bug, but taking the
  # connection down over it would also take away the way to ship the fix, so
  # it is reported to the caller and the connection left alone.
  defp encode(connection, message) do
    {:ok, connection.serializer.encode!(message)}
  rescue
    exception ->
      Logger.error(
        "[NervesHubLink] could not encode a #{inspect(message.event)} message: " <>
          Exception.message(exception)
      )

      {:error, {:encode_failure, exception}}
  end

  # Nested rather than one `with`, because both steps report failure as
  # `{:error, _, reason}` and only their position says which of the two it is.
  defp send_frame(connection, frame) do
    case Mint.WebSocket.encode(connection.websocket, frame) do
      {:ok, websocket, data} ->
        connection = %{connection | websocket: websocket}

        case Mint.WebSocket.stream_request_body(connection.conn, connection.request_ref, data) do
          {:ok, conn} ->
            {:ok, %{connection | conn: conn}}

          {:error, conn, reason} ->
            {:error, {:send_failure, transport_reason(reason)}, close(%{connection | conn: conn})}
        end

      {:error, websocket, reason} ->
        {:error, {:send_failure, transport_reason(reason)},
         close(%{connection | websocket: websocket})}
    end
  end

  ## Receiving

  defp handle_responses(connection, [], events), do: {connection, Enum.reverse(events)}

  # Nothing after the connection has gone can be acted on, and the responses
  # that follow a close belong to a connection that no longer exists.
  defp handle_responses(%{status: :closed} = connection, _responses, events) do
    {connection, Enum.reverse(events)}
  end

  defp handle_responses(connection, [response | rest], events) do
    {connection, new_events} = handle_response(connection, response)

    handle_responses(connection, rest, Enum.reverse(new_events) ++ events)
  end

  # The answer to the upgrade request can be split across as many messages as
  # the network feels like splitting it into, so each part is held until the
  # status and the headers are both in. Frames that arrive in the same packet
  # as the end of the response are kept too, and decoded once there is a
  # websocket to decode them with.
  defp handle_response(%{websocket: nil, request_ref: ref} = connection, {:status, ref, status}) do
    maybe_upgrade(%{connection | upgrade_status: status})
  end

  defp handle_response(%{websocket: nil, request_ref: ref} = connection, {:headers, ref, headers}) do
    maybe_upgrade(%{connection | upgrade_headers: headers})
  end

  defp handle_response(%{websocket: nil, request_ref: ref} = connection, {:data, ref, data}) do
    maybe_upgrade(%{connection | upgrade_data: [data | connection.upgrade_data]})
  end

  # The server finished answering without upgrading. Whatever it said, this is
  # not a websocket.
  defp handle_response(%{websocket: nil, request_ref: ref} = connection, {:done, ref}) do
    {close(connection), [{:disconnected, :upgrade_failure}]}
  end

  defp handle_response(%{request_ref: ref} = connection, {:data, ref, data}) do
    decode_frames(connection, data)
  end

  # The upgrade response is a completed HTTP response as well as the start of
  # a websocket, so Mint reports it done. There is nothing to do about that.
  defp handle_response(%{request_ref: ref} = connection, {:done, ref}) do
    {connection, []}
  end

  defp handle_response(%{request_ref: ref} = connection, {:error, ref, reason}) do
    {close(connection), [{:disconnected, transport_reason(reason)}]}
  end

  defp handle_response(connection, response) do
    Logger.debug("[NervesHubLink] ignoring an unexpected response : #{inspect(response)}")

    {connection, []}
  end

  defp maybe_upgrade(%{upgrade_status: nil} = connection), do: {connection, []}
  defp maybe_upgrade(%{upgrade_headers: nil} = connection), do: {connection, []}

  defp maybe_upgrade(connection) do
    case Mint.WebSocket.new(
           connection.conn,
           connection.request_ref,
           connection.upgrade_status,
           connection.upgrade_headers
         ) do
      {:ok, conn, websocket} ->
        buffered = connection.upgrade_data |> Enum.reverse() |> IO.iodata_to_binary()

        connection = %{
          connection
          | conn: conn,
            websocket: websocket,
            status: :connected,
            reconnect_count: 0,
            upgrade_status: nil,
            upgrade_headers: nil,
            upgrade_data: [],
            upgrade_timer: cancel_timer(connection.upgrade_timer)
        }

        {connection, events} = decode_frames(connection, buffered)

        {connection, [:connected | events]}

      {:error, conn, reason} ->
        {close(%{connection | conn: conn}), [{:disconnected, upgrade_failure(reason)}]}
    end
  end

  defp decode_frames(connection, "") do
    {connection, []}
  end

  defp decode_frames(connection, data) do
    case Mint.WebSocket.decode(connection.websocket, data) do
      {:ok, websocket, frames} ->
        handle_frames(%{connection | websocket: websocket}, frames, [])

      # Bytes that do not form frames mean the stream itself is no longer
      # trustworthy, so this one takes the connection rather than being
      # dropped the way a single unreadable frame is.
      {:error, websocket, reason} ->
        connection = close(%{connection | websocket: websocket})

        {connection, [{:disconnected, {:decode_failure, reason}}]}
    end
  end

  defp handle_frames(connection, [], events), do: {connection, Enum.reverse(events)}

  defp handle_frames(%{status: :closed} = connection, _frames, events) do
    {connection, Enum.reverse(events)}
  end

  defp handle_frames(connection, [frame | rest], events) do
    {connection, new_events} = handle_frame(connection, frame)

    handle_frames(connection, rest, Enum.reverse(new_events) ++ events)
  end

  defp handle_frame(connection, {:text, payload}), do: handle_payload(connection, payload, :text)

  defp handle_frame(connection, {:binary, payload}),
    do: handle_payload(connection, payload, :binary)

  defp handle_frame(connection, {:ping, data}) do
    case send_frame(connection, {:pong, data}) do
      {:ok, connection} -> {connection, []}
      {:error, reason, connection} -> {connection, [{:disconnected, reason}]}
    end
  end

  defp handle_frame(connection, {:pong, _data}), do: {connection, []}

  # A frame Mint could not read - a reserved opcode, a text frame that is not
  # valid UTF-8 - arrives as an entry in the frame list rather than as a
  # failure, because the rest of the batch may be perfectly good.
  defp handle_frame(connection, {:error, reason}) do
    Logger.warning("[NervesHubLink] dropping a frame that could not be read : #{inspect(reason)}")

    {connection, []}
  end

  defp handle_frame(connection, {:close, _code, _reason}) do
    {close(connection), [{:disconnected, :closed_by_remote}]}
  end

  defp handle_payload(connection, payload, opcode) do
    case decode(connection, payload, opcode) do
      {:ok, message} -> map_message(connection, message)
      :error -> {connection, []}
    end
  end

  # One frame the device cannot read is not a reason to lose the connection:
  # the next one may well be the update that fixes whatever sent it.
  defp decode(connection, payload, opcode) do
    {:ok, connection.serializer.decode!(payload, opcode)}
  rescue
    exception ->
      Logger.warning(
        "[NervesHubLink] dropping a frame that could not be decoded : " <>
          Exception.message(exception)
      )

      :error
  end

  ## Mapping messages to events

  defp map_message(%{heartbeat_ref: ref} = connection, %Message{ref: ref}) when is_binary(ref) do
    {%{connection | heartbeat_ref: nil}, []}
  end

  defp map_message(connection, %Message{event: "phx_error", topic: topic} = message) do
    {put_join_status(connection, topic, :closed),
     [{:topic_closed, topic, {:error, message.payload}}]}
  end

  defp map_message(connection, %Message{event: "phx_close", topic: topic}) do
    {put_join_status(connection, topic, :closed), [{:topic_left, topic}]}
  end

  # A reply sent with the ref that asked to join is the answer to that join -
  # but only to the join that ref belongs to. A topic that has since been
  # joined again has a new ref, and a late reply to the old one says nothing
  # about the new one, so taking it for an answer would report a topic joined
  # when its join is still unanswered.
  defp map_message(connection, %Message{event: "phx_reply", ref: ref, join_ref: ref} = message)
       when is_binary(ref) do
    topic = message.topic

    if current_join_ref?(connection, topic, ref) do
      map_join_reply(connection, topic, message)
    else
      Logger.debug(
        "[NervesHubLink] ignoring a reply to a join of #{topic} that has been superseded"
      )

      {connection, []}
    end
  end

  defp map_message(connection, %Message{event: "phx_reply", ref: ref} = message)
       when is_binary(ref) do
    case status_and_response(message.payload) do
      {status, response} -> {connection, [{:reply, ref, reply(status, response)}]}
      :error -> {connection, []}
    end
  end

  defp map_message(connection, %Message{ref: nil} = message) do
    {connection, [{:message, message.topic, message.event, message.payload}]}
  end

  defp map_message(connection, %Message{} = message) do
    Logger.debug("[NervesHubLink] ignoring an unexpected message : #{inspect(message)}")

    {connection, []}
  end

  defp map_join_reply(connection, topic, message) do
    case status_and_response(message.payload) do
      {"ok", response} ->
        connection =
          connection
          |> put_join_status(topic, :joined)
          |> update_join(topic, &%{&1 | rejoin_count: 0})

        {connection, [{:joined, topic, response}]}

      {_status, response} ->
        {put_join_status(connection, topic, :closed),
         [{:join_failed, topic, {:failed_to_join, response}}]}

      :error ->
        {connection, []}
    end
  end

  defp status_and_response(%{"status" => status, "response" => response})
       when is_binary(status) do
    {status, response}
  end

  defp status_and_response(_payload), do: :error

  # The status is matched rather than converted, so a status NervesHub invents
  # later cannot grow this device's atom table. One this version does not know
  # is passed through as it arrived rather than called an error, since Phoenix
  # lets a channel reply with any status it likes.
  defp reply("ok", response) when response == %{}, do: :ok
  defp reply("error", response) when response == %{}, do: :error
  defp reply("ok", response), do: {:ok, response}
  defp reply("error", response), do: {:error, response}
  defp reply(status, response), do: {status, response}

  ## Joins

  defp put_join_status(connection, topic, status) do
    update_join(connection, topic, &%{&1 | status: status})
  end

  defp update_join(%{joins: joins} = connection, topic, fun) do
    case joins do
      %{^topic => join} -> %{connection | joins: Map.put(joins, topic, fun.(join))}
      _ -> connection
    end
  end

  defp rejoin_count(%{joins: joins}, topic) do
    case joins do
      %{^topic => %{rejoin_count: count}} -> count
      _ -> 0
    end
  end

  defp current_join_ref?(%{joins: joins}, topic, ref) do
    case joins do
      %{^topic => %{ref: ^ref}} -> true
      _ -> false
    end
  end

  ## Connection plumbing

  defp reset(connection) do
    joins =
      Map.new(connection.joins, fn {topic, join} -> {topic, %{join | status: :closed}} end)

    %{
      connection
      | conn: nil,
        websocket: nil,
        request_ref: nil,
        upgrade_status: nil,
        upgrade_headers: nil,
        upgrade_data: [],
        upgrade_timer: cancel_timer(connection.upgrade_timer),
        heartbeat_ref: nil,
        status: :closed,
        joins: joins
    }
  end

  # A server that accepts the connection and then says nothing would otherwise
  # park the device there for as long as it felt like.
  defp schedule_upgrade_timeout(%{upgrade_timeout_msec: timeout}, _ref) when timeout in [0, nil],
    do: nil

  defp schedule_upgrade_timeout(%{upgrade_timeout_msec: timeout}, ref) do
    Process.send_after(self(), {:connection_upgrade_timeout, ref}, timeout)
  end

  defp cancel_timer(nil), do: nil

  defp cancel_timer(timer) do
    _ = Process.cancel_timer(timer)
    nil
  end

  defp next_ref(%{ref: ref} = connection) do
    next = ref + 1

    {Integer.to_string(next), %{connection | ref: next}}
  end

  defp upgrade_failure(%UpgradeFailureError{} = error), do: {:upgrade_failure, error}
  defp upgrade_failure(reason), do: reason

  defp transport_reason(%Mint.TransportError{reason: reason}), do: reason
  defp transport_reason(%Mint.HTTPError{reason: reason}), do: reason
  defp transport_reason(reason), do: reason

  defp http_scheme(%URI{scheme: "wss"}), do: :https
  defp http_scheme(%URI{}), do: :http

  defp ws_scheme(%URI{scheme: "wss"}), do: :wss
  defp ws_scheme(%URI{}), do: :ws

  # The query carries the `vsn` the serializer needs, so it travels with the
  # path rather than being dropped here.
  defp path(%URI{} = uri) do
    case uri.query do
      nil -> uri.path || "/"
      query -> "#{uri.path || "/"}?#{query}"
    end
  end
end
