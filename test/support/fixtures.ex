# Copy Paste of NervesHubCore.Support.Fwup
# As found https://github.com/nerves-hub/nerves_hub_web/blob/37290d5e21c1a082ca7dccfd07227cf296b4f45d/test/support/fwup.ex
defmodule Fwup.TestSupport.Fixtures do
  @moduledoc """
  This module is intended to help with testing and development
  by allowing for "easy" creation of firmware signing keys, and
  signed/unsigned/corrupted firmware files.

  It is a thin wrapper around `fwup`, and it persists the files in
  `System.tmp_dir()`.

  The files are given the names that are passed to the respective functions, so
  make sure you pass unique names to avoid collisions if necessary.  This module
  takes little effort to avoid collisions on its own.
  """

  defmodule MetaParams do
    @moduledoc false
    defstruct product: "nerves-hub",
              description: "D",
              version: "1.0.0",
              platform: "platform",
              architecture: "x86_64",
              author: "me"
  end

  @doc """
  Generate a public/private key pair for firmware signing. The `key_name`
  argument can be used to lookup the public key via `get_public_key/1` or to
  specify the private key to be used for signing a firmware image via
  `sign_firmware/3` and `create_signed_firmware/4`
  """
  @spec gen_key_pair(String.t()) :: :ok
  def(gen_key_pair(key_name)) do
    key_path_no_extension = Path.join([System.tmp_dir(), key_name])

    for ext <- ~w(.priv .pub) do
      _ = File.rm(key_path_no_extension <> ext)
    end

    {_, 0} = System.cmd("fwup", ["-g", "-o", key_path_no_extension], stderr_to_stdout: true)
    :ok
  end

  @doc """
  Get a public key which has been generated via `gen_key_pair/1`.
  """
  @spec get_public_key(String.t()) :: String.t()
  def get_public_key(key_name) do
    File.read!(Path.join([System.tmp_dir(), key_name <> ".pub"]))
  end

  @doc """
  Create an unsigned firmware image, and return the path to that image.
  """
  @spec create_firmware(String.t(), map()) :: {:ok, String.t()}
  def create_firmware(firmware_name, meta_params \\ %{}) do
    conf_path = make_conf(struct(MetaParams, meta_params))
    out_path = Path.join([System.tmp_dir(), firmware_name <> ".fw"])
    _ = File.rm(out_path)

    {_, 0} =
      System.cmd("fwup", [
        "-c",
        "-f",
        conf_path,
        "-o",
        out_path
      ])

    {:ok, out_path}
  end

  @doc """
  Sign a firmware image, and return the path to that image. The `firmware_name`
  argument must match the name of a firmware created with `create_firmware/2`.
  """
  @spec sign_firmware(String.t(), String.t(), String.t()) :: {:ok, String.t()}
  def sign_firmware(key_name, firmware_name, output_name) do
    dir = System.tmp_dir()
    output_path = Path.join([dir, output_name <> ".fw"])

    {_, 0} =
      System.cmd(
        "fwup",
        [
          "-S",
          "-s",
          Path.join([dir, key_name <> ".priv"]),
          "-i",
          Path.join([dir, firmware_name <> ".fw"]),
          "-o",
          output_path
        ],
        stderr_to_stdout: true
      )

    {:ok, output_path}
  end

  @doc """
  Create a signed firmware image, and return the path to that image.
  """
  @spec create_signed_firmware(String.t(), String.t(), String.t(), map()) :: {:ok, String.t()}
  def create_signed_firmware(key_name, firmware_name, output_name, meta_params \\ %{}) do
    {:ok, _} = create_firmware(firmware_name, meta_params)
    sign_firmware(key_name, firmware_name, output_name)
  end

  @doc """
  Corrupt an existing firmware image.
  """
  @spec corrupt_firmware_file(String.t(), String.t()) :: {:ok, String.t()}
  def corrupt_firmware_file(input_path, output_name \\ "corrupt") do
    output_path = Path.join([System.tmp_dir(), output_name <> ".fw"])
    :ok = File.cp!(input_path, output_path)

    {_, 0} =
      System.cmd("dd", ["if=/dev/urandom", "of=" <> output_path, "bs=512", "count=1"],
        stderr_to_stdout: true
      )

    {:ok, output_path}
  end

  defp make_conf(%MetaParams{} = meta_params) do
    path = Path.join([System.tmp_dir(), "#{Ecto.UUID.generate()}.conf"])
    File.write!(path, build_conf_contents(meta_params))

    path
  end

  defp build_conf_contents(%MetaParams{} = meta_params) do
    """
    meta-product = "#{meta_params.product}"
    meta-description = "#{meta_params.description} "
    meta-version = "#{meta_params.version}"
    meta-platform = "#{meta_params.platform}"
    meta-architecture = "#{meta_params.architecture}"
    meta-author = "#{meta_params.author}"

    file-resource hello.txt {
      contents = "Hello, world!"
    }

    task upgrade {
      on-resource hello.txt { raw_write(0) }
    }

    task secret_upgrade {
      on-resource hello.txt { raw_write(0, "cipher=aes-cbc-plain", "secret=\\${SUPER_SECRET}") }
    }
    """
  end
end
