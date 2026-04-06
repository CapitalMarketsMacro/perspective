from conan import ConanFile
from conan.tools.cmake import cmake_layout


class PerspectiveServerConan(ConanFile):
    name = "perspective-server"
    version = "4.3.0"
    settings = "os", "compiler", "build_type", "arch"
    generators = "CMakeToolchain", "CMakeDeps", "VirtualBuildEnv"

    def build_requirements(self):
        # protoc compiler is needed at build time for .proto code generation
        self.tool_requires("protobuf/<host_version>")

    def requirements(self):
        self.requires("arrow/[>=18.0.0]")
        self.requires("protobuf/5.27.0")
        self.requires("re2/20240702")
        self.requires("rapidjson/cci.20230929")
        self.requires("boost/1.86.0")
        self.requires("date/3.0.3")
        self.requires("tsl-hopscotch-map/2.3.1")
        self.requires("tsl-ordered-map/1.1.0")
        self.requires("exprtk/0.0.2")

        # Let abseil resolve to the latest version in range.
        # The pre-built re2/protobuf Conan binaries use abseil/20250127.0
        # even though re2's recipe pins 20240116.1 — override to match.
        self.requires("abseil/20250127.0", force=True)

    def configure(self):
        # We only need header-only Boost modules (algorithm, uuid,
        # functional, math, multi_index, dynamic_bitset).
        # header_only mode avoids building any compiled libraries and
        # sidesteps cross-dependency issues between newer Boost modules
        # (cobalt, process, etc.) that break selective disabling.
        self.options["boost"].header_only = True

        # Arrow: disable most optional features, enable CSV
        self.options["arrow"].with_csv = True
        self.options["arrow"].with_json = False
        self.options["arrow"].parquet = False
        self.options["arrow"].with_flight_rpc = False
        self.options["arrow"].gandiva = False
        self.options["arrow"].with_re2 = False
        self.options["arrow"].with_utf8proc = False
        self.options["arrow"].with_brotli = False
        self.options["arrow"].with_bz2 = False
        self.options["arrow"].with_lz4 = False
        self.options["arrow"].with_snappy = False
        self.options["arrow"].with_zlib = False
        self.options["arrow"].with_zstd = False
        self.options["arrow"].with_thrift = False

    def layout(self):
        cmake_layout(self)
