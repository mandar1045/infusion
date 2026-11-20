# Builds REPORT.md from data/*.jsonl. Run any time: mix run --no-start report.exs
Mix.install([{:jason, "~> 1.4"}])

dir = Path.join(__DIR__, "data")

read = fn kind ->
  path = Path.join(dir, "#{kind}.jsonl")

  if File.exists?(path) do
    path |> File.stream!() |> Enum.map(&Jason.decode!/1)
  else
    []
  end
end

polls = read.(:polls)
events = read.(:events)
checks = read.(:checks)
metrics = read.(:metrics)
requests = read.(:requests)
runs = read.(:runs)

ts = fn row -> {:ok, t, _} = DateTime.from_iso8601(row["t"]); t end
all_times = Enum.map(polls ++ events ++ checks ++ metrics, ts)
{first, last} = if all_times == [], do: {nil, nil}, else: Enum.min_max_by(all_times, &DateTime.to_unix/1)
hours = if first, do: DateTime.diff(last, first) / 3600, else: 0.0

pct = fn
  _, 0 -> "-"
  a, b -> "#{Float.round(a * 100 / b, 1)}%"
end

percentile = fn
  [], _ -> nil
  list, p ->
    sorted = Enum.sort(list)
    Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * (length(sorted) - 1))))
end

secs = fn
  nil -> "-"
  ms -> "#{Float.round(ms / 1000, 1)} s"
end

watchers = (polls ++ events ++ checks) |> Enum.map(& &1["watcher"]) |> Enum.reject(&(&1 in [nil, "unknown"])) |> Enum.uniq() |> Enum.sort()

# Per watcher
rows =
  for w <- watchers do
    p = Enum.filter(polls, &(&1["watcher"] == w))
    e = Enum.filter(events, &(&1["watcher"] == w))
    c = Enum.filter(checks, &(&1["watcher"] == w and is_nil(&1["error"])))
    by = Enum.frequencies_by(e, & &1["type"])
    pages = Enum.sum(Enum.map(p, & &1["pages"]))
    nm = Enum.sum(Enum.map(p, & &1["not_modified"]))
    # Only where the item's own update time moved (a new item, or an update
    # that changed updated_at / last_updated): other changes don't bump it,
    # so measuring from it would be meaningless.
    lat =
      e
      |> Enum.filter(fn ev ->
        ev["type"] == "created" or
          (ev["type"] == "updated" and Enum.any?(ev["changes"] || [], &(&1 in ["updated_at", "last_updated"])))
      end)
      |> Enum.map(& &1["latency_ms"])
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1 >= 0))

    %{
      w: w,
      polls: length(p),
      pages: pages,
      not_modified: nm,
      created: by["created"] || 0,
      updated: by["updated"] || 0,
      deleted: by["deleted"] || 0,
      entered: by["entered"] || 0,
      errors: by["error"] || 0,
      resyncs: by["resync"] || 0,
      checks: length(c),
      compared: Enum.sum(Enum.map(c, & &1["fresh"])),
      transient: Enum.sum(Enum.map(c, &(&1["missing"] + &1["changed"] + &1["extra"] - &1["persistent"]))),
      persistent: Enum.sum(Enum.map(c, & &1["persistent"])),
      details: Enum.flat_map(c, & &1["persistent_details"]),
      p50: percentile.(lat, 50),
      p95: percentile.(lat, 95),
      check_errors: Enum.count(checks, &(&1["watcher"] == w and &1["error"]))
    }
  end

rate = Enum.filter(metrics, &(&1["kind"] == "github_rate" and is_nil(&1["error"])))

# GitHub's own counter: sum the increases (it resets every hour).
counted =
  rate
  |> Enum.chunk_every(2, 1, :discard)
  |> Enum.map(fn [a, b] -> if b["used"] >= a["used"], do: b["used"] - a["used"], else: b["used"] end)
  |> Enum.sum()

# Requests in the same window as the rate-limit samples (rows are written
# each minute for the minute before).
{rate_from, rate_to} =
  case rate do
    [] -> {nil, nil}
    _ -> {ts.(hd(rate)), ts.(List.last(rate))}
  end

in_window = fn row ->
  rate_from != nil and DateTime.compare(ts.(row), DateTime.add(rate_from, 60, :second)) != :lt and
    DateTime.compare(ts.(row), rate_to) != :gt
end

github_rows = Enum.filter(requests, &(&1["host"] == "api.github.com" and in_window.(&1)))
github_sent = github_rows |> Enum.map(& &1["count"]) |> Enum.sum()
github_304 = github_rows |> Enum.filter(&(&1["status"] == 304)) |> Enum.map(& &1["count"]) |> Enum.sum()
github_counted_200 = github_sent - github_304

statuses =
  requests
  |> Enum.group_by(&{&1["host"], &1["status"]})
  |> Enum.map(fn {{h, s}, l} -> {h, s, Enum.sum(Enum.map(l, & &1["count"]))} end)
  |> Enum.sort()

vm = Enum.filter(metrics, &(&1["kind"] == "vm"))
mem = Enum.map(vm, & &1["memory_total"])

mem_line =
  case vm do
    [] -> "-"
    _ ->
      mb = &Float.round(&1 / 1_048_576, 1)
      "start #{mb.(hd(mem))} MB, end #{mb.(List.last(mem))} MB, max #{mb.(Enum.max(mem))} MB"
  end

watcher_mem =
  case vm do
    [] -> []
    _ ->
      firsts = hd(vm)["watcher_memory"]
      lasts = List.last(vm)["watcher_memory"]
      for {k, v} <- Enum.sort(lasts), do: "#{k}: #{Float.round((firsts[k] || 0) / 1024)} KB -> #{Float.round(v / 1024)} KB"
  end

total_persistent = Enum.sum(Enum.map(rows, & &1.persistent))
total_compared = Enum.sum(Enum.map(rows, & &1.compared))
total_events = Enum.sum(Enum.map(rows, &(&1.created + &1.updated + &1.deleted + &1.entered)))

table = fn header, lines ->
  sep = header |> Enum.map(fn _ -> "---" end) |> Enum.join(" | ")
  Enum.join(["| " <> Enum.join(header, " | ") <> " |", "| " <> sep <> " |" | Enum.map(lines, &("| " <> Enum.join(&1, " | ") <> " |"))], "\n")
end

report = """
# Infusion watchers: real-world soak test

Generated #{DateTime.utc_now() |> DateTime.truncate(:second)}. Data: #{if first, do: "#{DateTime.truncate(first, :second)} to #{DateTime.truncate(last, :second)}", else: "none"} (#{Float.round(hours, 2)} hours), #{length(runs)} start(s).

Five watchers, started with `async: true` under a supervisor, sending events to
replicas that rebuild each list from events alone. Every 10 minutes a checker
fetches each real list directly and compares it with the replica. A difference
seen in two checks in a row while the real item didn't change is a **missed
change**; other differences are timing (the list changed between the watcher's
poll and the checker's fetch).

## Summary

  * Correctness: **#{total_persistent} missed changes** in #{total_compared} item comparisons
  * Events delivered: #{total_events}
  * GitHub requests sent (between the first and last rate-limit samples): #{github_sent},
    of which #{github_304} were `304 Not Modified` (#{pct.(github_304, github_sent)}) and #{github_counted_200} were not;
    GitHub's own rate-limit counter went up by **#{counted}** over the same time
    (the checker's direct fetches and the rate-limit reads are included in the requests)
  * Memory (whole VM): #{mem_line}

## Per watcher

#{table.(~w(watcher polls pages 304s created updated deleted entered errors restarts), Enum.map(rows, fn r -> [r.w, r.polls, r.pages, "#{r.not_modified} (#{pct.(r.not_modified, r.pages)})", r.created, r.updated, r.deleted, r.entered, r.errors, max(r.resyncs - 0, 0)] |> Enum.map(&to_string/1) end))}

## Correctness

#{table.(["watcher", "checks", "items compared", "timing differences", "missed changes"], Enum.map(rows, fn r -> [r.w, r.checks, r.compared, r.transient, r.persistent] |> Enum.map(&to_string/1) end))}

#{if total_persistent == 0, do: "No missed changes.", else: "Missed changes:\n\n" <> Enum.map_join(rows, "\n", fn r -> Enum.map_join(r.details, "\n", &"  * #{r.w}: #{&1["kind"]} #{inspect(&1["id"])} #{Enum.join(&1["fields"], ", ")}") end)}

## Latency

From the item's own `updated_at` / `last_updated` (server clock) to the event
arriving, for new items and for updates that moved that timestamp. It is the
poll interval plus the time the API takes to show a change in its lists.

#{table.(["watcher", "p50", "p95"], Enum.map(rows, &[&1.w, secs.(&1.p50), secs.(&1.p95)]))}

## Requests by status

#{table.(["host", "status", "count"], Enum.map(statuses, fn {h, s, n} -> [to_string(h), to_string(s), to_string(n)] end))}

## Memory per watcher process

#{Enum.map_join(watcher_mem, "\n", &"  * #{&1}")}
"""

File.write!(Path.join(__DIR__, "REPORT.md"), report)
IO.puts(report)
