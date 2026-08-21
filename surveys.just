# Survey pipelines over real-world geometry: fetch -> solve every
# region -> plot. Research/example tooling, separate from the dev loop.

# Fetch the US-states GeoJSON -> scripts/states/data/states.json (cached).
states-gen:
    uv run scripts/states/gen_states.py

# Solve every state -> states_aspect.json (needs states-gen).
states-aspect:
    zig build states-aspect

# One PNG per state, boundary + enclosing-cone ellipse (needs states-aspect).
states-plot:
    uv run scripts/states/states_plot.py

# Full states pipeline: fetch -> solve -> plot.
states-all: states-gen states-aspect states-plot

# Fetch the Natural Earth countries GeoJSON -> scripts/countries/data/countries.json (cached).
countries-gen:
    uv run scripts/countries/gen_countries.py

# Solve every country -> countries_aspect.json (needs countries-gen; over-hemisphere countries are skipped, not failures).
countries-aspect:
    zig build countries-aspect

# One PNG per converged country (needs countries-aspect).
countries-plot:
    uv run scripts/countries/countries_plot.py

# Full countries pipeline: fetch -> solve -> plot.
countries-all: countries-gen countries-aspect countries-plot

# Regenerate the batch fixtures cases/batches/*.{ids,zon}.
batches-gen:
    uv run scripts/batches/gen_batches.py

# Check every committed batch .zon against its .ids by vertex chord distance.
batches-verify:
    uv run scripts/batches/verify_batches.py

# Remove generated survey data.
clean:
    rm -rf scripts/states/data scripts/countries/data
