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
        self.requires("arrow/18.1.0")
        self.requires("protobuf/5.27.0")
        self.requires("re2/20240702")
        self.requires("rapidjson/cci.20230929")
        self.requires("boost/1.86.0")
        self.requires("date/3.0.3")
        self.requires("tsl-hopscotch-map/2.3.1")
        self.requires("tsl-ordered-map/1.1.0")
        self.requires("exprtk/0.0.2")

        # Force abseil version that satisfies both protobuf (range >=20230802.1)
        # and re2/20240702 (hard-pins 20240116.1).
        self.requires("abseil/20240116.1", force=True)

    def configure(self):
        # We only need specific Boost modules but Conan's boost recipe
        # builds header-only by default which covers algorithm, uuid,
        # functional, math, multi_index, dynamic_bitset.
        self.options["boost"].without_atomic = True
        self.options["boost"].without_chrono = True
        self.options["boost"].without_container = True
        self.options["boost"].without_context = True
        self.options["boost"].without_contract = True
        self.options["boost"].without_coroutine = True
        self.options["boost"].without_date_time = True
        self.options["boost"].without_exception = True
        self.options["boost"].without_fiber = True
        self.options["boost"].without_filesystem = True
        self.options["boost"].without_graph = True
        self.options["boost"].without_graph_parallel = True
        self.options["boost"].without_iostreams = True
        self.options["boost"].without_json = True
        self.options["boost"].without_locale = True
        self.options["boost"].without_log = True
        self.options["boost"].without_mpi = True
        self.options["boost"].without_nowide = True
        self.options["boost"].without_program_options = True
        self.options["boost"].without_python = True
        self.options["boost"].without_random = True
        self.options["boost"].without_regex = True
        self.options["boost"].without_serialization = True
        self.options["boost"].without_stacktrace = True
        self.options["boost"].without_test = True
        self.options["boost"].without_thread = True
        self.options["boost"].without_timer = True
        self.options["boost"].without_type_erasure = True
        self.options["boost"].without_wave = True

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
        self.options["arrow"].with_zstd = False
        self.options["arrow"].with_thrift = False

    def layout(self):
        cmake_layout(self)
