// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ialert_flutter",
    platforms: [.iOS("13.0")],
    products: [.library(name: "ialert-flutter", targets: ["ialert_flutter"])],
    dependencies: [.package(name: "FlutterFramework", path: "../FlutterFramework")],
    targets: [
        .target(name: "ialert_flutter", dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")]),
    ]
)
