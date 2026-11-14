defmodule Infusion.Runtime.Request do
  @moduledoc """
  Sends one API call: builds the HTTP request from an operation, retries it
  when that is safe, and decodes the response.

  Generated SDKs call `run/5` with an operation described as data:

      %{
        id: "retrieveModel",
        method: :get,
        path: "/models/{model}",
        path_params: ["model"],
        # {option key, name on the wire, location}
        params: [{:limit, "limit", :query}, {:organization, "OpenAI-Organization", :header}],
        body: nil | :json | :form | :multipart,
        response: Infusion.Runtime.Schema type | nil,
        server: nil | "https://other.host"
      }

  Parameters are given as a map or keyword list. Known ones go where the
  operation says; unknown ones go into the body, or into the query when the
  operation has no body, so parameters added to the API after the SDK was
  generated can still be sent.

  ## Retries

  Like the official SDKs: up to `max_retries` (2) retries on connection
  errors, timeouts, 408, 409, 429 and 5xx. A `x-should-retry` response
  header overrides that decision either way. The wait is the server's
  `retry-after-ms` or `retry-after` when given (up to a minute), otherwise
  `min(0.5s * 2^n, 8s)` minus up to 25% jitter.

  ## Options of a call

  Any `Infusion.Runtime.Config` setting (`timeout`, `max_retries`,
  `headers`, `api_key`, ...), plus:

    * `raw: true`: return `{:ok, %Req.Response{}}` with the decoded body,
      for headers and status
    * `idempotency_key: "..."`: use this key instead of a generated one

  ## Telemetry

  `[:infusion, :request, :start | :stop | :exception]`, with `:operation`,
  `:method` and `:url` in the metadata; `:stop` adds `:status` (or
  `:error`) and `:retries`.
  """

  alias Infusion.Runtime.{Config, Error, Form, Schema, SSE}

  @retry_statuses [408, 409, 429]
  @max_server_delay 60_000

  @doc "Runs `operation` with the positional `path_args`, `params` and call `opts`."
  @spec run(Config.t(), map, [term], map | keyword | term, keyword) ::
          {:ok, term} | {:error, Error.t()}
  def run(%Config{} = config, operation, path_args, params, opts \\ []) do
    config = Config.merge(config, opts)
    request = build(config, operation, path_args, params, opts)
    meta = %{operation: operation[:id], method: operation.method, url: request.url}

    :telemetry.span([:infusion, :request], meta, fn ->
      {result, retries} = attempt(request, config, 0)
      stop = Map.merge(meta, stop_meta(result, retries))
      {finish(result, operation, config, opts), stop}
    end)
  end

  @doc """
  Runs a streaming operation: `{:ok, stream}` of decoded events, or
  `{:error, error}` when the request fails before any event arrives.

  The operation says how to ask for a stream (`stream_param: {"stream", true}`)
  and how to decode each event (`stream_response`). Until the response
  starts, the request is retried like any other; once events flow it never
  is. The stream is lazy and must be consumed by the process that called
  this; stopping early (`Enum.take/2`) closes the connection. An error the
  API sends inside the stream is raised as `Infusion.Runtime.Error`. A
  `data: [DONE]` event ends the stream.
  """
  @spec stream(Config.t(), map, [term], map | keyword | term, keyword) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream(%Config{} = config, operation, path_args, params, opts \\ []) do
    config = Config.merge(config, opts)
    params = put_stream_param(params, operation[:stream_param])
    request = build(config, operation, path_args, params, opts)
    meta = %{operation: operation[:id], method: operation.method, url: request.url}

    :telemetry.span([:infusion, :request], meta, fn ->
      {result, retries} = attempt(%{request | into: :self}, config, 0)
      stop = Map.merge(meta, stop_meta(result, retries))

      result =
        case result do
          {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
            events = events(response, operation)
            if opts[:raw], do: {:ok, %{response | body: events}}, else: {:ok, events}

          other ->
            finish(other, operation, config, opts)
        end

      {result, stop}
    end)
  end

  @doc "Unwraps a result for the `!` functions: returns the value or raises the error."
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, %Error{} = error}), do: raise(error)

  ## Building

  defp build(config, op, path_args, params, opts) do
    {query, headers, body} = split_params(op, params)

    # `url` is a full URL to follow, such as the next page's.
    url =
      op[:url] ||
        (op[:server] || config.base_url || "") <> path(op.path, op[:path_params] || [], path_args)

    url =
      case Form.pairs(query, :repeat) do
        [] -> url
        pairs -> url <> separator(url) <> URI.encode_query(pairs, :rfc3986)
      end

    headers =
      Enum.map(config.headers, fn {k, v} -> {to_string(k), to_string(v)} end) ++
        Enum.map(headers, fn {k, v} -> {k, to_string(v)} end) ++
        auth_header(config) ++
        idempotency(config, op.method, opts) ++
        content_type(op, body)

    {url, auth_query} = auth_query(url, config)

    %{
      method: op.method,
      url: url <> auth_query,
      # The URL without a credential in its query, for following relative links.
      public_url: url,
      headers: headers,
      body: encode_body(op[:body], body, config),
      into: nil
    }
  end

  # Some paths carry a query already (OpenAI's "/responses?beta=true").
  defp separator(url), do: if(String.contains?(url, "?"), do: "&", else: "?")

  defp path(template, names, args) when length(names) == length(args) do
    Enum.zip(names, args)
    |> Enum.reduce(template, fn {name, value}, acc ->
      String.replace(acc, "{#{name}}", URI.encode(to_string(value), &URI.char_unreserved?/1))
    end)
  end

  defp path(template, names, args) do
    raise ArgumentError,
          "#{template} takes #{length(names)} path parameters, got #{length(args)}"
  end

  # Returns {query, headers, body}. A body that isn't a map or keyword list
  # (an array, a binary upload) is sent as it is.
  defp split_params(op, params) when is_map(params) or params == [] or is_tuple(hd(params)) do
    known = Map.new(op[:params] || [], fn {key, name, where} -> {key, {name, where}} end)
    by_name = Map.new(op[:params] || [], fn {_key, name, where} -> {name, {name, where}} end)
    default = if op[:body], do: :body, else: :query

    Enum.reduce(params, {[], [], []}, fn {key, value}, {query, headers, body} ->
      {name, where} =
        Map.get(known, key) || Map.get(by_name, to_string(key)) || {to_string(key), default}

      cond do
        value == nil -> {query, headers, body}
        where == :query -> {[{name, value} | query], headers, body}
        where == :header -> {query, [{name, value} | headers], body}
        true -> {query, headers, [{name, value} | body]}
      end
    end)
    |> then(fn {q, h, b} -> {Enum.reverse(q), Enum.reverse(h), Map.new(b)} end)
  end

  defp split_params(_op, body), do: {[], [], body}

  defp encode_body(nil, body, _config) when body == %{}, do: nil
  defp encode_body(_type, body, _config) when body == %{}, do: nil

  defp encode_body(:form, body, config),
    do: {:form, Form.encode(Schema.encode(body), config.form_style)}

  defp encode_body(:multipart, body, _config), do: {:multipart, multipart(body)}
  defp encode_body(_json, body, _config) when is_binary(body), do: {:binary, body}
  defp encode_body(_json, body, _config), do: {:json, Schema.encode(body)}

  # Req's form_multipart takes values as binaries, {binary, opts} or File.Stream.
  defp multipart(body) do
    Enum.flat_map(body, fn {name, value} ->
      case value do
        list when is_list(list) -> Enum.map(list, &{name, part(&1)})
        value -> [{name, part(value)}]
      end
    end)
  end

  defp part(%File.Stream{} = file), do: file
  defp part({data, opts}) when is_binary(data) and is_list(opts), do: {data, opts}
  defp part(value) when is_binary(value), do: value

  defp part(value) when is_map(value) and not is_struct(value),
    do: Jason.encode!(Schema.encode(value))

  defp part(value), do: to_string(Schema.encode(value))

  defp auth_header(config) do
    case {config.auth, Config.credential(config)} do
      {_, nil} -> []
      {:bearer, key} -> [{"authorization", "Bearer " <> to_string(key)}]
      {:basic, {user, pass}} -> [{"authorization", "Basic " <> Base.encode64("#{user}:#{pass}")}]
      {:basic, key} -> [{"authorization", "Basic " <> Base.encode64(to_string(key))}]
      {{:header, name}, key} -> [{name, to_string(key)}]
      _ -> []
    end
  end

  defp auth_query(url, config) do
    case {config.auth, Config.credential(config)} do
      {{:query, name}, key} when key != nil ->
        {url, separator(url) <> URI.encode_query([{name, to_string(key)}], :rfc3986)}

      _ ->
        {url, ""}
    end
  end

  # JSON variants (application/merge-patch+json) and raw bodies (text/plain,
  # application/octet-stream) say what they are; Req sets the rest.
  defp content_type(%{content_type: type}, body) when is_binary(type) and body != %{},
    do: [{"content-type", type}]

  defp content_type(_op, _body), do: []

  defp idempotency(%Config{idempotency_header: nil}, _method, _opts), do: []
  defp idempotency(_config, method, _opts) when method in [:get, :head], do: []

  defp idempotency(config, _method, opts) do
    key =
      opts[:idempotency_key] ||
        "infusion-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    [{config.idempotency_header, key}]
  end

  ## Sending, with retries

  defp attempt(request, config, retries) do
    headers =
      if config.retry_count_header,
        do: request.headers ++ [{config.retry_count_header, to_string(retries)}],
        else: request.headers

    result = send_request(%{request | headers: headers}, config)

    if retries < config.max_retries and retry?(result) do
      wait(config, delay(result, retries))
      attempt(request, config, retries + 1)
    else
      {result, retries}
    end
  end

  defp send_request(request, config) do
    body_opts =
      case request.body do
        nil ->
          []

        {:json, data} ->
          [json: data]

        {:form, encoded} ->
          [body: encoded, headers: [{"content-type", "application/x-www-form-urlencoded"}]]

        {:multipart, parts} ->
          [form_multipart: parts]

        {:binary, data} ->
          [body: data]
      end

    options =
      [
        method: request.method,
        url: request.url,
        headers: request.headers,
        retry: false,
        receive_timeout: config.timeout
      ] ++
        if(config.user_agent, do: [user_agent: config.user_agent], else: []) ++
        if(request.into, do: [into: request.into], else: [])

    options
    |> Req.new()
    |> Req.merge(body_opts)
    |> Req.merge(config.req_options)
    |> Req.request()
    |> read_unless_streaming()
    |> case do
      {:ok, response} ->
        {:ok, Req.Response.put_private(response, :infusion_url, request.public_url)}

      error ->
        error
    end
  end

  # A streamed request that didn't get an event stream back (an error, or
  # a plain JSON answer) is read in full, so it is handled like any other.
  defp read_unless_streaming(
         {:ok, %Req.Response{body: %Req.Response.Async{}} = response} = result
       ) do
    if response.status in 200..299 and event_stream?(response) do
      result
    else
      body = response.body |> Enum.to_list() |> IO.iodata_to_binary()
      {:ok, %{response | body: decode_json(body, response)}}
    end
  end

  defp read_unless_streaming(result), do: result

  defp event_stream?(response) do
    Enum.any?(
      Req.Response.get_header(response, "content-type"),
      &String.starts_with?(&1, "text/event-stream")
    )
  end

  defp decode_json(body, response) do
    json? =
      Enum.any?(Req.Response.get_header(response, "content-type"), &String.contains?(&1, "json"))

    with true <- json?, {:ok, json} <- Jason.decode(body) do
      json
    else
      _ -> body
    end
  end

  defp retry?({:error, _exception}), do: true

  defp retry?({:ok, %Req.Response{status: status} = response}) do
    case Req.Response.get_header(response, "x-should-retry") do
      ["true" | _] -> true
      ["false" | _] -> false
      _ -> status in @retry_statuses or status >= 500
    end
  end

  @doc false
  # The wait before retry number `retries + 1`, in milliseconds.
  def delay({:ok, %Req.Response{} = response}, retries) do
    case server_delay(response) do
      ms when is_number(ms) and ms > 0 and ms <= @max_server_delay -> round(ms)
      _ -> backoff(retries)
    end
  end

  def delay(_error, retries), do: backoff(retries)

  defp backoff(retries) do
    base = min(500 * Integer.pow(2, retries), 8_000)
    round(base * (1 - :rand.uniform() * 0.25))
  end

  defp server_delay(response) do
    with [] <- Req.Response.get_header(response, "retry-after-ms"),
         [value | _] <- Req.Response.get_header(response, "retry-after") do
      retry_after(value)
    else
      [ms | _] -> parse_number(ms)
      [] -> nil
    end
  end

  defp retry_after(value) do
    case parse_number(value) do
      nil -> http_date_delay(value)
      seconds -> seconds * 1000
    end
  end

  defp parse_number(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # "Wed, 21 Oct 2015 07:28:00 GMT"
  defp http_date_delay(value) do
    with [_, d, mon, y, h, m, s] <-
           Regex.run(~r/\A\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/, value),
         month when month != nil <- Enum.find_index(@months, &(&1 == mon)),
         {:ok, date} <- Date.new(String.to_integer(y), month + 1, String.to_integer(d)),
         {:ok, time} <- Time.new(String.to_integer(h), String.to_integer(m), String.to_integer(s)),
         {:ok, at} <- DateTime.new(date, time) do
      DateTime.diff(at, DateTime.utc_now(), :millisecond)
    else
      _ -> nil
    end
  end

  defp wait(%Config{sleep: nil}, ms), do: Process.sleep(ms)
  defp wait(%Config{sleep: sleep}, ms), do: sleep.(ms)

  ## Results

  defp finish({:error, exception}, _op, _config, _opts),
    do: {:error, Error.from_exception(exception)}

  defp finish({:ok, %Req.Response{status: status} = response}, op, _config, opts)
       when status in 200..299 do
    decoded = decode(response.body, op[:response])
    if opts[:raw], do: {:ok, %{response | body: decoded}}, else: {:ok, decoded}
  end

  defp finish({:ok, %Req.Response{} = response}, _op, config, _opts) do
    {:error,
     Error.from_response(
       response.status,
       response.body,
       response.headers,
       request_id(response, config)
     )}
  end

  ## Streams

  defp put_stream_param(params, nil), do: params

  defp put_stream_param(params, {name, value}) when is_map(params) or is_list(params) do
    if params == [] or is_map(params) or is_tuple(hd(params)) do
      params
      |> Enum.reject(fn {key, _} -> to_string(key) == name end)
      |> Kernel.++([{name, value}])
    else
      params
    end
  end

  defp put_stream_param(params, _), do: params

  defp events(%Req.Response{body: %Req.Response.Async{} = body}, op) do
    body
    |> Stream.transform(&SSE.new/0, &SSE.parse(&2, &1), &{SSE.flush(&1), &1}, fn _ -> :ok end)
    |> Stream.transform(:ok, fn event, acc ->
      case decode_event(event, op) do
        :done -> {:halt, acc}
        :skip -> {[], acc}
        {:ok, value} -> {[value], acc}
      end
    end)
  end

  # 2xx but not an event stream: the API answered in one piece.
  defp events(%Req.Response{body: body}, op), do: [decode(body, op[:response])]

  defp decode_event(%SSE.Event{data: "[DONE]"}, _op), do: :done
  defp decode_event(%SSE.Event{data: ""}, _op), do: :skip

  defp decode_event(%SSE.Event{event: name, data: data}, op) do
    case Jason.decode(data) do
      {:ok, %{"error" => error} = json} when is_map(error) or name == "error" ->
        raise Error.from_stream(json)

      {:ok, json} when name == "error" ->
        raise Error.from_stream(json)

      {:ok, json} ->
        {:ok, decode(json, op[:stream_response])}

      {:error, _} ->
        {:ok, data}
    end
  end

  defp decode("", _type), do: nil
  defp decode(body, nil), do: body
  defp decode(body, type) when is_map(body) or is_list(body), do: Schema.decode(body, type)
  defp decode(body, _type), do: body

  defp request_id(response, config) do
    Enum.find_value(config.request_id_headers, fn name ->
      case Req.Response.get_header(response, name) do
        [id | _] -> id
        [] -> nil
      end
    end)
  end

  defp stop_meta({:ok, %Req.Response{status: status}}, retries),
    do: %{status: status, retries: retries}

  defp stop_meta({:error, exception}, retries),
    do: %{status: nil, error: exception, retries: retries}
end
