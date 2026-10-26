# `:vector_preview` needs a TypeDB build with vector support, which no release is
# yet, so it is opted into on its own with `--include vector_preview`.
ExUnit.start(exclude: [:integration, :vector_preview])
