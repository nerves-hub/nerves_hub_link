# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Connection.Serializer do
  @moduledoc """
  Turns a `NervesHubLink.Connection.Message` into a websocket frame, and back.

  A serializer is paired with the protocol version the server selects it by,
  which travels in the socket URL's `vsn` query parameter. The two have to
  agree, or the server will read the frames as something they are not.

  ## Failing

  `c:encode!/1` raises `NervesHubLink.Connection.Serializer.EncodeError` and
  `c:decode!/2` raises `NervesHubLink.Connection.Serializer.DecodeError`, both
  with a message describing what could not be handled.

  A serializer does not have to limit itself to those two: the connection treats
  any exception raised while decoding as a malformed frame, logs it and drops
  the frame, rather than letting one bad frame from the server take the
  connection down with it.
  """

  alias NervesHubLink.Connection.Message

  @typedoc "A websocket data frame, as `Mint.WebSocket` represents one"
  @type frame :: {:text, binary()} | {:binary, binary()}

  @typedoc "Which kind of data frame a payload arrived in"
  @type opcode :: :text | :binary

  @doc """
  Encode a message into the frame to send.
  """
  @callback encode!(Message.t()) :: frame()

  @doc """
  Decode the payload of a received frame into a message.
  """
  @callback decode!(payload :: binary(), opcode()) :: Message.t()

  @doc """
  Turn a `ref` from the wire into the string the connection stores.

  `NervesHubLink.Connection` allocates refs as strings and matches a reply to
  what it answers by comparing them, so a ref that arrives as a number has to
  be converted or it matches nothing - and the reply it belongs to is lost
  without a word. Anything that is neither a string, a number nor absent is not
  a ref at all and is refused.
  """
  # `term()` is the honest argument type - refusing what it is given is half of
  # the job - but it is wider than the types dialyzer sees reaching it, which
  # this project's `:underspecs` reports.
  @dialyzer {:nowarn_function, to_ref: 1}
  @spec to_ref(term()) :: String.t() | nil
  def to_ref(nil), do: nil
  def to_ref(ref) when is_binary(ref), do: ref
  def to_ref(ref) when is_integer(ref), do: Integer.to_string(ref)

  def to_ref(ref) do
    raise __MODULE__.DecodeError,
      message: "expected a ref that is a string, a number or null, got: #{inspect(ref)}"
  end
end

defmodule NervesHubLink.Connection.Serializer.EncodeError do
  @moduledoc """
  Raised when a message cannot be encoded for sending.
  """

  defexception [:message]
end

defmodule NervesHubLink.Connection.Serializer.DecodeError do
  @moduledoc """
  Raised when a received frame cannot be decoded into a message.
  """

  defexception [:message]
end
