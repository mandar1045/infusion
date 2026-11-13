# Tests tagged :specs load real vendor specs (megabytes each), so they only
# run when INFUSION_SPECS points at a folder holding openai.yaml,
# openai.json and cloudflare.json.
specs? = System.get_env("INFUSION_SPECS") not in [nil, ""]
if not specs?, do: IO.puts("Skipping :specs tests, as INFUSION_SPECS isn't set")

ExUnit.start(exclude: if(specs?, do: [], else: [:specs]))
