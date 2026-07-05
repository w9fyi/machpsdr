// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WDSPKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CWDSP", targets: ["CWDSP"])
    ],
    targets: [
        // Command-line smoke test (not part of the app).
        .executableTarget(name: "wdspcheck", dependencies: ["CWDSP"]),
        // Warren Pratt (NR0V) WDSP DSP library — vendored from g0orx/wdsp (GPL).
        // The Swift-visible API is the clean, dependency-free `wdsp.h` umbrella.
        .target(
            name: "CWDSP",
            cSettings: [
                // FFTW headers (Homebrew). `-w` silences the library's own warnings.
                // RNNoise headers back the NR3 (RNNoise) filter in rnnr.c, vendored
                // from ThirdParty/rnnoise with our HF-radio-retrained weights baked in.
                .unsafeFlags([
                    "-I/opt/homebrew/include",
                    "-I/Users/justinmann/Desktop/devprojects/machpsdr/ThirdParty/rnnoise/include",
                    "-w"
                ]),
                .define("_GNU_SOURCE")
            ],
            linkerSettings: [
                // Statically link double-precision FFTW (WDSP uses the `fftw_` API)
                // and RNNoise (NR3) so nothing external is needed at runtime.
                .unsafeFlags([
                    "/opt/homebrew/lib/libfftw3.a",
                    "/Users/justinmann/Desktop/devprojects/machpsdr/ThirdParty/rnnoise/lib/librnnoise.a"
                ])
            ]
        )
    ]
)
