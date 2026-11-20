import SwiftUI

/// The main actions as a row at the top of the chat list. The system toolbar folds the last buttons into «»» whenever the
/// window is not wide enough; this row cannot be folded, so every action stays in sight.
struct SidebarActionBar: View {
    let newGroup: () -> Void
    let contacts: () -> Void
    let calls: () -> Void
    let createConference: () -> Void
    let joinCall: () -> Void
    let openLink: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            item("square.and.pencil", "Новая группа или канал", newGroup)
            item("person.crop.circle", "Контакты", contacts)
            item("phone.badge.clock", "История звонков", calls)
            Menu {
                Button("Создать конференцию…", action: createConference)
                Button("Присоединиться по ссылке…", action: joinCall)
            } label: {
                Image(systemName: "video.badge.plus").frame(width: 30, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Конференция: создать или присоединиться по ссылке")
            item("link", "Открыть ссылку MAX", openLink)
            Spacer(minLength: 0)
            item("gearshape", "Настройки", settings)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func item(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 30, height: 26).contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(help)
    }
}
