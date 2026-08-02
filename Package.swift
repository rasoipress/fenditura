// swift-tools-version: 5.9
import PackageDescription

// Due bersagli, e la divisione non è cosmetica.
//
// FenditturaCore non importa niente di grafico: è la matematica della
// scansione, e si verifica in un secondo con `swift test`. Tutti i difetti
// seri della versione precedente stavano lì dentro — la misura del moto
// sbagliata di un fattore intero, le piastrelle che perdevano una frangia,
// il PNG troncato — e nessuno si vedeva aprendo l'applicazione.
//
// Fenditura è l'eseguibile: SwiftUI e AVFoundation, cioè la parte che
// soltanto macOS può eseguire e che nessuna prova automatica copre.
//
// Il linguaggio resta alla versione 5: il modo 6 impone il controllo rigido
// della concorrenza, che su un motore con un solo attore principale produce
// soltanto rumore.

let package = Package(
    name: "Fenditura",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fenditura", targets: ["Fenditura"]),
        .library(name: "FenditturaCore", targets: ["FenditturaCore"])
    ],
    targets: [
        .target(name: "FenditturaCore"),
        .executableTarget(name: "Fenditura", dependencies: ["FenditturaCore"]),
        .testTarget(name: "FenditturaCoreTests", dependencies: ["FenditturaCore"])
    ],
    swiftLanguageVersions: [.v5]
)
