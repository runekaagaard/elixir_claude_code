defmodule ClaudeCode.Content.ImageBlock do
  @moduledoc """
  Represents an image content block within a Claude message.

  Image blocks contain base64-encoded image data, typically from tool results
  (e.g. Playwright screenshots) or user-attached images.
  """

  @enforce_keys [:type, :source]
  defstruct [:type, :source]

  @type source :: %{
          type: String.t(),
          media_type: String.t(),
          data: String.t()
        }

  @type t :: %__MODULE__{
          type: :image,
          source: source()
        }

  @doc """
  Creates a new Image content block from JSON data.

  ## Examples

      iex> ImageBlock.new(%{"type" => "image", "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "..."}})
      {:ok, %ImageBlock{type: :image, source: %{type: "base64", media_type: "image/png", data: "..."}}}
  """
  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(%{"type" => "image", "source" => source}) when is_map(source) do
    {:ok, %__MODULE__{type: :image, source: source}}
  end

  def new(%{"type" => "image"}), do: {:error, :missing_source}
  def new(_), do: {:error, :invalid_content_type}
end

defimpl Jason.Encoder, for: ClaudeCode.Content.ImageBlock do
  def encode(block, opts) do
    block
    |> ClaudeCode.JSONEncoder.to_encodable()
    |> Jason.Encoder.Map.encode(opts)
  end
end

defimpl JSON.Encoder, for: ClaudeCode.Content.ImageBlock do
  def encode(block, encoder) do
    block
    |> ClaudeCode.JSONEncoder.to_encodable()
    |> JSON.Encoder.Map.encode(encoder)
  end
end
