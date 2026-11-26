import Foundation
@preconcurrency import Photos
import UIKit

/// Candidato foto della galleria: dati minimi per scegliere senza toccare le immagini.
struct FotoCandidata: Equatable, Sendable {
    var id: String
    var data: Date
    var selfie: Bool
}

/// Selezione della foto da usare come volto: l'ultimo SELFIE vince su tutto,
/// altrimenti l'ultima foto del rullino. Funzione pura (testabile senza Photos).
enum SceltaFoto {
    static func migliore(_ candidati: [FotoCandidata]) -> FotoCandidata? {
        guard !candidati.isEmpty else { return nil }
        let ordinate = candidati.sorted { $0.data > $1.data }
        return ordinate.first(where: { $0.selfie }) ?? ordinate.first
    }
}

/// Ritaglio del volto: cerchio centrato sull'immagine, con lato massimo controllato,
/// per applicarla sopra la testa dell'avatar (3D e 2D) senza muovere file di megabyte in texture.
enum RitaglioViso {
    static func cerchio(_ image: UIImage, latoMax: CGFloat = 1024) -> UIImage? {
        let lato = min(image.size.width, image.size.height)
        guard lato > 0 else { return nil }
        let scala = min(1, latoMax / lato)
        let formato = UIGraphicsImageRendererFormat()
        formato.opaque = false
        formato.scale = max(image.scale, 1)
        let latoFinale = lato * scala
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: latoFinale, height: latoFinale), format: formato)
        return renderer.image { _ in
            let percorsoCerchio = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: latoFinale, height: latoFinale))
            percorsoCerchio.addClip()
            image.draw(in: CGRect(
                x: -(image.size.width - lato) / 2 * scala,
                y: -(image.size.height - lato) / 2 * scala,
                width: image.size.width * scala,
                height: image.size.height * scala
            ))
        }
    }
}

/// Esito della sincronizzazione automatica con la galleria.
enum EsitoGalleria: Sendable {
    case foto(Data)
    case nessunaFoto
    case permessoNegato
    case errore
}

/// Lettura automatica dalla galleria: prende l'ultimo selfie e, se non esiste,
/// l'ultima foto del rullino. Serve l'accesso alla libreria Foto (uso: solo lettura),
/// chiesto una volta sola. Le foto restano dentro la sandbox dell'app: nessuna rete, nessun server.
@MainActor
enum GalleriaFoto {
    static func sincronizza() async -> EsitoGalleria {
        let permesso = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch permesso {
        case .authorized, .limited:
            break
        case .denied, .restricted, .notDetermined:
            return .permessoNegato
        @unknown default:
            return .permessoNegato
        }

        let opzioni = PHFetchOptions()
        opzioni.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var candidati: [FotoCandidata] = []
        var visti = Set<String>()
        func aggiungi(_ asset: PHAsset, selfie: Bool) {
            guard candidati.count < 200, visti.insert(asset.localIdentifier).inserted else { return }
            candidati.append(FotoCandidata(
                id: asset.localIdentifier,
                data: asset.creationDate ?? .distantPast,
                selfie: selfie
            ))
        }
        // 1) gli selfie (album "Selfies" del sistema): e' il segnale piu' sicuro
        let selfieAlbum = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumSelfPortraits,
            options: nil
        )
        for indiceAlbum in 0..<selfieAlbum.count {
            let album = selfieAlbum.object(at: indiceAlbum)
            let risorse = PHAsset.fetchAssets(in: album, options: opzioni)
            for indice in 0..<risorse.count {
                aggiungi(risorse.object(at: indice), selfie: true)
            }
        }
        // 2) tutto il rullino di immagini come riserva (Memoji salvato, foto, ecc.)
        let rullino = PHAsset.fetchAssets(with: .image, options: opzioni)
        for indice in 0..<rullino.count {
            aggiungi(rullino.object(at: indice), selfie: false)
        }

        guard let scelta = SceltaFoto.migliore(candidati),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [scelta.id], options: nil).firstObject
        else { return .nessunaFoto }

        let gestore = PHImageManager.default()
        let opzioniImmagine = PHImageRequestOptions()
        opzioniImmagine.deliveryMode = .highQualityFormat
        opzioniImmagine.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuazione in
            gestore.requestImage(
                for: asset,
                targetSize: CGSize(width: 1200, height: 1200),
                contentMode: .aspectFit,
                options: opzioniImmagine
            ) { immagine, _ in
                if let dati = immagine?.jpegData(compressionQuality: 0.85) {
                    continuazione.resume(returning: .foto(dati))
                } else {
                    continuazione.resume(returning: .errore)
                }
            }
        }
    }
}
