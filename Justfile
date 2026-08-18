# Justfile for bin-zig (Zig port of marcosnils/bin)

set shell := ["pwsh", "-Command"]

# Default: build the project in Debug mode
default: build

# Build the project in ReleaseSafe mode (optimized)
build:
    zig build -Doptimize=ReleaseSafe
    @echo "Build complete. Binary is at zig-out/bin/bin"

# Build the project in Debug mode
debug:
    zig build
    @echo "Debug build complete."

# Install the binary to the system (requires bin_dir to be set in config)
# This uses the bin-zig executable itself to "self-manage" if you have it in path, 
# but for a first time install, we just copy it.
install: build
    @echo "Please move zig-out/bin/bin to your desired binary directory."

# Download and install Zig (v0.15.2) for Windows
install-zig:
    $ver = "0.15.2"
    $url = "https://ziglang.org/download/0.15.2/zig-x86_64-windows-0.15.2.zip"
    $dest = "zig-windows.zip"
    $extractDir = "zig-compiler"
    echo "Downloading Zig $ver..."
    Invoke-WebRequest -Uri $url -OutFile $dest
    echo "Extracting Zig..."
    Expand-Archive -Path $dest -DestinationPath $extractDir -Force
    Remove-Item $dest
    $zigPath = Get-ChildItem -Path "$extractDir\zig-x86_64-windows-$ver" | Select-Object -ExpandProperty FullName
    echo "Zig installed to: $zigPath"
    echo "Add this to your PATH to use 'zig' command."

# Clean build artifacts
clean:
    if (Test-Path .zig-cache) { Remove-Item -Recurse -Force .zig-cache }
    if (Test-Path zig-out) { Remove-Item -Recurse -Force zig-out }
    @echo "Cleaned build artifacts."

# Run the binary with help
help: build
    ./zig-out/bin/bin --help
