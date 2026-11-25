import SwiftUI
import UIKit

struct PhotoCard: View {
    @Environment(AppStore.self) private var store
    @State private var showCamera = false
    @State private var cameraError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Foto di riferimento (automatica)", systemImage: "camera.fill")
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
            if let data = store.photoData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Text("L'app scatta da sé una foto con la fotocamera frontale: non pesca dalla galleria e non la carica da nessuna parte, resta solo dentro la sandbox dell'app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                haptic(.medium)
                if UIImagePickerController.isSourceTypeAvailable(.camera),
                   UIImagePickerController.isCameraDeviceAvailable(.front) {
                    showCamera = true
                } else {
                    cameraError = "Fotocamera frontale non disponibile in questo contesto (simulatore o limitazioni del container). La scansione viso TrueDepth resta il modo migliore per avere il tuo viso reale sull'avatar."
                }
            } label: {
                Label(store.photoData == nil ? "Scatta foto ora" : "Riscatta foto", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.gold)
        }
        .card()
        .padding(.horizontal)
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.8) {
                    store.setPhoto(data)
                }
            }
        }
        .alert("Fotocamera", isPresented: Binding(
            get: { cameraError != nil },
            set: { if !$0 { cameraError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cameraError ?? "")
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
