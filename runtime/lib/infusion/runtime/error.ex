defmodule Infusion.Runtime.Error do
  @moduledoc """
  The error every SDK call returns as `{:error, %Infusion.Runtime.Error{}}`.

  `type` tells what went wrong, so callers can match on it instead of on
  status codes:

  | type | when |
  |---|---|
  | `:bad_request` | 400 |
  | `:authentication` | 401 |
  | `:permission_denied` | 403 |
  | `:not_found` | 404 |
  | `:conflict` | 409 |
  | `:unprocessable_entity` | 422 |
  | `:rate_limit` | 429, or any status with `x-ratelimit-remaining: 0` (GitHub sends 403) |
  | `:internal_server` | 500 and above |
  | `:api_error` | any other status of 400 and above, or an error event in a stream |
  | `:timeout` | no response in time |
  | `:connection` | the request could not be sent or the connection broke |

  For status errors, `body` is the decoded response body, `headers` the
  response headers and `request_id` the API's request ID, if it sent one
  (quote it when contacting the vendor's support). For `:timeout` and
  `:connection`, `reason` holds the underlying error.
  """

  defexception [:type, :status, :message, :body, :request_id, :reason, headers: %{}]

  @type type ::
          :bad_request
          | :authentication
          | :permission_denied
          | :not_found
          | :conflict
          | :unprocessable_entity
          | :rate_limit
          | :internal_server
          | :api_error
          | :timeout
          | :connection

  @type t :: %__MODULE__{
          type: type,
          status: non_neg_integer | nil,
          message: String.t(),
          body: term,
          headers: %{optional(String.t()) => [String.t()]},
          request_id: String.t() | nil,
          reason: term
        }

  @doc false
  def from_response(status, body, headers, request_id) do
    %__MODULE__{
      type: if(rate_limited?(headers), do: :rate_limit, else: type(status)),
      status: status,
      message: message(status, body),
      body: body,
      headers: headers,
      request_id: request_id
    }
  end

  @doc false
  # An error event inside a stream that had already started.
  def from_stream(body) do
    %__MODULE__{
      type: :api_error,
      message: detail(body) || "error event in the stream",
      body: body
    }
  end

  @doc false
  def from_exception(exception) do
    reason = Map.get(exception, :reason, exception)

    %__MODULE__{
      type: if(reason == :timeout, do: :timeout, else: :connection),
      message:
        if(reason == :timeout, do: "request timed out", else: Exception.message(exception)),
      reason: reason
    }
  end

  # GitHub answers 403, not 429, when the rate limit is used up.
  defp rate_limited?(headers) do
    headers
    |> Map.get("x-ratelimit-remaining", [])
    |> List.wrap()
    |> Enum.member?("0")
  end

  defp type(400), do: :bad_request
  defp type(401), do: :authentication
  defp type(403), do: :permission_denied
  defp type(404), do: :not_found
  defp type(409), do: :conflict
  defp type(422), do: :unprocessable_entity
  defp type(429), do: :rate_limit
  defp type(status) when status >= 500, do: :internal_server
  defp type(_status), do: :api_error

  # APIs put the human-readable message in different places.
  defp message(status, body) do
    case detail(body) do
      nil -> "HTTP #{status}"
      detail -> "#{status}: #{detail}"
    end
  end

  defp detail(body) do
    case body do
      %{"error" => %{"message" => m}} when is_binary(m) -> m
      %{"error" => m} when is_binary(m) -> m
      %{"message" => m} when is_binary(m) -> m
      %{"errors" => [%{"message" => m} | _]} when is_binary(m) -> m
      %{"detail" => m} when is_binary(m) -> m
      m when is_binary(m) and m != "" and byte_size(m) < 500 -> m
      _ -> nil
    end
  end
end
