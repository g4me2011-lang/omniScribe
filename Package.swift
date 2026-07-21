// swift-tools-version: 5.9
//
// Package.swift – OmniScribe
//
// Skirtas dviem tikslams:
//   1. `swift build`  – patikrinti kompiliavimą terminale be Xcode.
//   2. `swift package resolve` – iš anksto atsisiųsti WhisperKit priklausomybę.
//
// PASTABA: `swift build` sukuria ELF vykdomąjį failą, NE .app paketą.
// Pilną .app su Info.plist ir entitlements reikia kurti per Xcode
// (arba `xcodebuild`). Package.swift ir .xcodeproj gali egzistuoti šalia –
// jie dalinasi tais pačiais šaltinio failais.

import PackageDescription

let package = Package(
    name: "OmniScribe",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // WhisperKit – CoreML optimizuotas Whisper macOS/iOS platformoms.
        // Palaiko Apple Silicon (ANE akceleracija) ir Intel (CPU fallback).
        .package(
            url: "https://github.com/argmaxinc/WhisperKit",
            from: "0.9.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "OmniScribe",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "OmniScribe",
            // Info.plist ir .entitlements naudojami Xcode; SPM build jų nereikia.
            exclude: [
                "Info.plist",
                "OmniScribe.entitlements",
                "Assets.xcassets"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
