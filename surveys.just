# Survey pipelines over real-world geometry (US states, world
# countries): fetch data, run the solver over every region, plot the
# results. Research/example tooling, separate from the dev loop —
# invoke as `just surveys::<recipe>`, list with `just --list surveys`.

# Fetch + cache the US-states GeoJSON and write scripts/states/data/states.json.
states-gen:
    uv run scripts/states/gen_states.py

# Depends on `just surveys::states-gen` having run first.
# Run csar over every US state; writes scripts/states/data/states_aspect.json.
states-aspect:
    zig build states-aspect

# Depends on `just surveys::states-aspect` having written states_aspect.json.
# Plot one PNG per state (boundary + enclosing-cone ellipse) into the data dir.
states-plot:
    uv run scripts/states/states_plot.py

# Full states example in one command: fetch -> solve -> plot.
states-all: states-gen states-aspect states-plot

# Output is gitignored; the GeoJSON is cached after the first run.
# Fetch + cache the Natural Earth countries GeoJSON (ranked by area) and write scripts/countries/data/countries.json.
countries-gen:
    uv run scripts/countries/gen_countries.py

# Countries that exceed a hemisphere are reported and skipped (not a
# failure). Depends on `just surveys::countries-gen` having run first.
# Run csar over every country; writes scripts/countries/data/countries_aspect.json.
countries-aspect:
    zig build countries-aspect

# Depends on `just surveys::countries-aspect` having written countries_aspect.json.
# Plot one PNG per converged country (boundary + enclosing-cone ellipse).
countries-plot:
    uv run scripts/countries/countries_plot.py

# Full countries example in one command: fetch -> solve -> plot.
countries-all: countries-gen countries-aspect countries-plot

# Remove the generated survey data (fetched GeoJSON stays cached upstream).
clean:
    rm -rf scripts/states/data scripts/countries/data
