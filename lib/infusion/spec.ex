defmodule Infusion.Spec do
  @moduledoc """
  Loads an OpenAPI document from a file or a URL.

      {:ok, spec} = Infusion.Spec.load("openapi.json")
      {:ok, spec} = Infusion.Spec.load("https://example.com/openapi.yaml")

  JSON and YAML are both accepted, told apart by content rather than by file
  extension. Prefer JSON when a vendor publishes both: it is about 50 times
  faster to parse. YAML is read with full YAML type resolution, so `true`,
  `false` and `null` arrive as booleans and `nil` (a faster YAML library was
  measured returning them as strings, which silently changes meaning, e.g.
  `additionalProperties: "false"`).

  Only OpenAPI 3.0 and 3.1 are supported.
  """

  defstruct [:document, :version, :source]

  @type t :: %__MODULE__{document: map, version: String.t(), source: String.t()}

  @doc """
  Loads and checks an OpenAPI document.

  ## Options

    * `:req_options` - extra options for `Req.get/2` when `source` is a URL.
  """
  @spec load(String.t(), keyword) :: {:ok, t} | {:error, String.t()}
  def load(source, opts \\ []) when is_binary(source) do
    with {:ok, content} <- read(source, opts),
         {:ok, document} <- decode(content),
         {:ok, version} <- version(document) do
      {:ok, %__MODULE__{document: document, version: version, source: source}}
    else
      {:error, reason} -> {:error, "could not load #{source}: #{reason}"}
    end
  end

  defp read("http://" <> _ = url, opts), do: fetch(url, opts)
  defp read("https://" <> _ = url, opts), do: fetch(url, opts)

  defp read(path, _opts) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, :file.format_error(reason) |> to_string()}
    end
  end

  defp fetch(url, opts) do
    req_options =
      [url: url, decode_body: false, retry: :transient] ++ Keyword.get(opts, :req_options, [])

    case Req.get(req_options) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  # JSON when the first non-whitespace character opens an object or array,
  # else YAML.
  defp decode(content) do
    case String.trim_leading(content) do
      "{" <> _ -> decode_json(content)
      "[" <> _ -> decode_json(content)
      _ -> decode_yaml(content)
    end
  end

  defp decode_json(content) do
    case JSON.decode(content) do
      {:ok, %{} = document} -> {:ok, document}
      {:ok, _other} -> {:error, "the JSON is not an object"}
      {:error, reason} -> {:error, "invalid JSON (#{inspect(reason)})"}
    end
  end

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, %{} = document} -> {:ok, document}
      {:ok, _other} -> {:error, "the YAML is not a mapping"}
      {:error, %{message: message}} -> {:error, "invalid YAML (#{message})"}
      {:error, reason} -> {:error, "invalid YAML (#{inspect(reason)})"}
    end
  end

  defp version(%{"openapi" => "3.0" <> _ = version}), do: {:ok, version}
  defp version(%{"openapi" => "3.1" <> _ = version}), do: {:ok, version}

  defp version(%{"openapi" => other}),
    do: {:error, "OpenAPI #{other} is not supported, only 3.0 and 3.1"}

  defp version(%{"swagger" => _}),
    do:
      {:error,
       "this is a Swagger 2.0 document; convert it to OpenAPI 3 first, " <>
         "for example with swagger2openapi"}

  defp version(_), do: {:error, "not an OpenAPI document (no \"openapi\" field)"}
end
