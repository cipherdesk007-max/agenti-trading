import PhotosUI
import SwiftUI
import UIKit

struct PhotoCard: View {
    @Environment(AppStore.self) private var store
    @State private var item: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Foto di riferimento", systemImage: "person.crop.rectangle")
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
                Text("Scegli una foto dal rullino: resta solo dentro la sandbox dell'app su questo iPhone, non viene mai inviata da nessuna parte.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            PhotosPicker(selection: $item, matching: .images) {
                Label(store.photoData == nil ? "Scegli foto" : "Cambia foto", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.accent)
        }
        .card()
        .padding(.horizontal)
        .task(id: item) {
            guard let item else { return }
            if let data = try? await item.loadTransferable(type: Data.self) {
                store.setPhoto(data)
            }
        }
    }
}
