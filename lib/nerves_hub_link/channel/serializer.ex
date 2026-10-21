# SPDX-FileCopyrightText: 2026 Josh Kalderimis
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesHubLink.Channel.Serializer do
  @moduledoc """
  Turns a `NervesHubLink.Channel.Message` into a websocket frame, and back.

  A serializer is paired with the protocol version the server selects it by,
  which travels in the socket URL's `vsn` query parameter. The two have to
  agree, or the server will read the frames as something they are not.

  ## Failing

  `c:encode!/1` raises `NervesHubLink.Channel.Serializer.EncodeError` and
  `c:decode!/2` raises `NervesHubLink.Channel.Serializer.DecodeError`, both
  with a message describing what could not be handled.

  A serializer does not have to limit itself to those two: the channel treats
  any exception raised while decoding as a malformed frame, logs it and drops
  the frame, rather than letting one bad frame from the server take the
  connection down with it.
  """

  alias NervesHubLink.Channel.Message

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
end

defmodule NervesHubLink.Channel.Serializer.EncodeError do
  @moduledoc """
  Raised when a message cannot be encoded for sending.
  """

  defexception [:message]
end

defmodule NervesHubLink.Channel.Serializer.DecodeError do
  @moduledoc """
  Raised when a received frame cannot be decoded into a message.
  """

  defexception [:message]
end
