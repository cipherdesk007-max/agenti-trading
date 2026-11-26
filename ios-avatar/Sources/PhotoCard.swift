import PhotosUI
import SwiftUI
import UIKit

extension Notification.Name {
    static let avatarFitFotoScelta = Notification.Name("AvatarFitFotoScelta")
}

struct PhotoCard: View {
    @Environment(AppStore.self) private var store
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var sincronizza = false
    @State private var messaggio: String?

    private var immagine: UIImage? {
        store.faceImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Volto dell'avatar (Memoji o selfie)", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                if store.photoData != nil {
                    Button(role: .destructive) {
                        store.clearPhoto()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            if let immagine {
                Image(uiImage: immagine)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Questo volto è ora applicato sulla testa dell'avatar (3D e 2D) in Home. Resta solo dentro la sandbox dell'app: nessuna galleria svuotata, nessun invio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("iOS non lascia leggere le Memoji alle app di terze parti: salvala tu in Foto (Messaggi > Memoji > sticker > tieni premuto > Salva in Immagini) oppure usa uno selfie. Poi scegli qui sotto, oppure attiva la lettura automatica: l'app prende da sola l'ultimo selfie della galleria.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                haptic(.medium)
                showPicker = true
            } label: {
                Label("Scegli dalla galleria", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)

            Toggle(isOn: Binding(
                get: { store.autoGalleryFace },
                set: { nuovo in
                    store.autoGalleryFace = nuovo
                    if nuovo { sincronizzaAdesso() }
                }
            )) {
                Label("Automatica dalla galleria", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
            }
            .tint(Theme.gold)

            if sincronizza {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Cerco l'ultimo selfie nella galleria…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                haptic(.medium)
                if UIImagePickerController.isSourceTypeAvailable(.camera),
                   UIImagePickerController.isCameraDeviceAvailable(.front) {
                    showCamera = true
                } else {
                    messaggio = "Fotocamera frontale non disponibile in questo contesto (simulatore o limitazioni del container). La via che funziona sempre è dall'album: salva un selfie o il tuo Memoji in Foto e attiva la lettura automatica, oppure sceglici tu dalla galleria."
                }
            } label: {
                Label("Scatta selfie (registrata in locale)", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .card()
        .padding(.horizontal)
        .onAppear {
            if store.autoGalleryFace {
                sincronizzaAdesso()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .avatarFitFotoScelta)) { nota in
            guard let immagineScelta = nota.object as? UIImage else { return }
            // la scelta manuale vince: la lettura automatica si spegne
            store.autoGalleryFace = false
            if let dati = immagineScelta.jpegData(compressionQuality: 0.85) {
                store.setPhoto(dati)
                haptic(.medium)
            }
        }
        .sheet(isPresented: $showPicker) {
            // l'immagine scelta arriva con la notifica .avatarFitFotoScelta (onReceive qui sopra)
            GalleriaPicker()
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { immagineScelta in
                store.autoGalleryFace = false
                if let dati = immagineScelta.jpegData(compressionQuality: 0.8) {
                    store.setPhoto(dati)
                }
            }
        }
        .alert("Galleria", isPresented: Binding(
            get: { messaggio != nil },
            set: { if !$0 { messaggio = nil } }
        )) {
            Button("Apri Impostazioni") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(messaggio ?? "")
        }
    }

    private func sincronizzaAdesso() {
        guard !sincronizza else { return }
        sincronizza = true
        Task { @MainActor in
            let esito = await GalleriaFoto.sincronizza()
            sincronizza = false
            switch esito {
            case .foto(let dati):
                store.setPhoto(dati)
                haptic(.medium)
            case .nessunaFoto:
                messaggio = "Nessuna immagine in galleria: scatta uno selfie o salva il tuo Memoji in Foto e riprova."
            case .permessoNegato:
                store.autoGalleryFace = false
                messaggio = "Permesso Foto negato: senza accesso in lettura l'app non può prendere l'ultimo selfie. Attiva Foto in Impostazioni (con LiveContainer può servire darlo all'app contenitore) e riprova."
            case .errore:
                messaggio = "Lettura della foto non riuscita (immagine non più disponibile o in iCloud senza rete). Riprova più tardi o sceglici tu dalla galleria."
            }
        }
    }
}

struct GalleriaPicker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configurazione = PHPickerConfiguration()
        configurazione.filter = .images
        configurazione.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configurazione)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            // il completion handler di loadObject e' @Sendable: qui si cattura SOLO UIImage (Sendable),
            // il passaggio alla vista avviene con una notifica consegnata sul MainActor
            provider.loadObject(ofClass: UIImage.self) { oggetto, _ in
                guard let immagine = oggetto as? UIImage else { return }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .avatarFitFotoScelta, object: immagine)
                }
            }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .front
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void

        init(onImage: @escaping (UIImage) -> Void) {
            self.onImage = onImage
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
