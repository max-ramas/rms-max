import SwiftUI
import RMSMaxCore
import UniformTypeIdentifiers

struct ProfileEditView: View {
    @EnvironmentObject private var store: AppStore
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var descriptionText = ""
    @State private var loaded = false
    @State private var showingPhotoImporter = false

    private var me: MaxContact? {
        store.currentAccount?.userId.flatMap { store.contacts[$0] }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    AvatarView(url: me?.avatarURL ?? store.currentAccount?.avatarURL, title: store.currentAccount?.displayName ?? "", size: 88)
                    if let phone = store.currentAccount?.phone {
                        Text(phone.hasPrefix("+") ? phone : "+" + phone).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            Section("Имя") {
                TextField("Имя", text: $firstName, prompt: Text("Имя"))
                TextField("Фамилия", text: $lastName, prompt: Text("Фамилия"))
            }

            Section("О себе") {
                TextField("Описание", text: $descriptionText, prompt: Text("Пара слов о себе"), axis: .vertical)
            }

            Section {
                Button("Сменить фото") { showingPhotoImporter = true }
            }

            Section {
                Button("Сохранить") {
                    let first = firstName.trimmedForm
                    let last = lastName.trimmedForm
                    let desc = descriptionText.trimmedForm
                    Task {
                        await store.updateProfile(firstName: first, lastName: last, description: desc.isEmpty ? nil : desc)
                    }
                }
                .disabled(firstName.trimmedForm.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Профиль")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            firstName = me?.firstName ?? store.currentAccount?.displayName ?? ""
            lastName = me?.lastName ?? ""
            descriptionText = me?.description ?? ""
        }
        .fileImporter(isPresented: $showingPhotoImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, let photo = PhotoFileImport.load(url) else { return }
            Task {
                await store.setProfilePhoto(data: photo.data, mime: photo.mime)
            }
        }
    }
}
