# `:vector_alpha` needs a TypeDB build with vector support, which no release is
# yet, so it is opted into on its own with `--include vector_alpha`.
ExUnit.start(exclude: [:integration, :vector_alpha])
