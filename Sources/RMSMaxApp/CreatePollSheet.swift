import SwiftUI
import RMSMaxCore

struct CreatePollSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    @State private var title = ""
    @State private var options = ["", ""]
    @State private var anonymous = true
    @State private var multiple = false
    @State private var revote = true
    @State private var sending = false

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Вопрос") { TextField("Вопрос", text: $title) }
                Section("Варианты ответа") {
                    ForEach(options.indices, id: \.self) { i in
                        HStack {
                            TextField("Вариант \(i + 1)", text: $options[i])
                            if options.count > 2 {
                                Button { options.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                    if options.count < 10 {
                        Button { options.append("") } label: { Label("Добавить вариант", systemImage: "plus.circle") }
                    }
                }
                Section {
                    Toggle("Анонимное голосование", isOn: $anonymous)
                    Toggle("Несколько ответов", isOn: $multiple)
                    Toggle("Можно переголосовать", isOn: $revote)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Новый опрос")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        sending = true
                        Task {
                            if await store.sendPoll(chatId: chatId, title: title, options: options, anonymous: anonymous, multiple: multiple, revote: revote) { dismiss() }
                            sending = false
                        }
                    }
                    .disabled(!valid || sending)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 440)
    }
}
