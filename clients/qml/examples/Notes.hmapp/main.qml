// Notes: a small QML app for Hyprmux, and the test app for QML apps (docs/QML.md).
//
// - A list of notes and an editor. ⌘N makes a note, ⌘S saves.
// - Import… and Export… open and save text files, in sheets over the tile.
// - Right-click a note: open it in a window of its own (⌘⇧N), export, or delete.
// - Pinch the editor to zoom its text.
// - Closing with unsaved changes asks first.
// - Hyprmux brings back its windows, note windows too, when it restores a session.
// - One copy runs ("instances": "single"). Opening Notes again offers its notes in
//   Hyprmux's picker: the list, or one note in a window.
//
// Hyprmux's own binds win: its default config binds ⌘N and ⌘S, so they reach the
// app only when its pass list hands them over (docs/QML.md, Keyboard):
//   app:dev.gavrix.hyprmux.notes { pass = SUPER N, SUPER S }
pragma ComponentBehavior: Bound

import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Hyprmux

HyprmuxWindow {
    id: window
    title: "Notes" + (store.dirty ? " •" : "")
    restoreToken: "main"

    // Every note, saved as JSON in the app's settings. Each has an id, so a window
    // showing it can come back after a restart.
    QtObject {
        id: store
        property var notes: {
            const loaded = JSON.parse(settings.notes || "[]")
            return loaded.map((n, i) => n.id ? n : Object.assign({ id: Date.now() + i }, n))
        }
        property int current: notes.length > 0 ? 0 : -1
        property bool dirty: false

        function add(title, body) {
            const n = notes.slice()
            n.unshift({ id: Date.now(), title: title || "New note", body: body || "" })
            notes = n
            current = 0
            dirty = true
            editor.forceActiveFocus()
        }
        function update(body) {
            if (current < 0) return
            const n = notes.slice()
            const firstLine = body.split("\n")[0].trim()
            n[current] = Object.assign({}, n[current], { title: firstLine || "Untitled", body: body })
            notes = n
            dirty = true
        }
        function remove(index) {
            const n = notes.slice()
            n.splice(index, 1)
            notes = n
            current = Math.min(current, n.length - 1)
            dirty = true
        }
        function save() {
            settings.notes = JSON.stringify(notes)
            dirty = false
        }
        function find(id) { return notes.find(n => String(n.id) === String(id)) }
    }

    Settings {
        id: settings
        category: "notes"
        property string notes: ""
    }

    function openWindow(note) {
        if (note) noteWindow.createObject(null, { noteId: note.id })
    }

    Connections {
        target: HyprmuxApp
        property bool first: true
        function onLaunched() {
            // A restored session: the note windows it had, by their restore tokens.
            for (const token of HyprmuxApp.restoreTokens)
                if (token.startsWith("note:")) window.openWindow(store.find(token.slice(5)))
            // Opened again while running: which window?
            if (!first && store.notes.length > 0)
                HyprmuxApp.offer([{ id: "main", title: "Notes", detail: store.notes.length + " notes" }]
                    .concat(store.notes.map(n => ({ id: String(n.id), title: n.title, detail: "In a window of its own" }))))
            else if (!first)
                window.activate()
            first = false
        }
        function onOpenRequested(id) {
            if (id === "main") window.activate()
            else window.openWindow(store.find(id))
        }
    }

    Shortcut { sequences: [StandardKey.New]; onActivated: store.add() }
    Shortcut { sequences: [StandardKey.Save]; onActivated: store.save() }
    Shortcut {
        sequence: "Ctrl+Shift+N"   // ⌘⇧N: Qt names Command "Ctrl" on macOS
        enabled: store.current >= 0
        onActivated: window.openWindow(store.notes[store.current])
    }

    // Closing with unsaved changes: ask, in a sheet, and keep the window until answered.
    onClosing: close => {
        if (!store.dirty) return
        close.accepted = false
        unsaved.open()
    }

    MessageDialog {
        id: unsaved
        text: "Save changes to your notes?"
        informativeText: "Your changes are lost if you don't save them."
        buttons: MessageDialog.Save | MessageDialog.Cancel | MessageDialog.Discard
        onButtonClicked: button => {
            if (button === MessageDialog.Save) store.save()
            if (button !== MessageDialog.Cancel) { store.dirty = false; window.close() }
        }
    }

    FileDialog {
        id: importDialog
        title: "Import a note"
        nameFilters: ["Text (*.txt *.md)", "All files (*)"]
        onAccepted: {
            const text = Files.readText(selectedFile)
            const name = selectedFile.toString().split("/").pop().replace(/\.[^.]*$/, "")
            store.add(decodeURIComponent(name), text)
        }
    }

    FileDialog {
        id: exportDialog
        title: "Export the note"
        fileMode: FileDialog.SaveFile
        acceptLabel: "Export"
        nameFilters: ["Text (*.txt)"]
        property int index: -1
        onAccepted: {
            if (!Files.writeText(selectedFile, store.notes[index].body)) failed.open()
        }
        function exportNote(i) {
            index = i
            selectedFile = store.notes[i].title + ".txt"
            open()
        }
    }

    MessageDialog {
        id: failed
        text: "Couldn't export the note."
        informativeText: Files.lastError
    }

    MessageDialog {
        id: confirmDelete
        property int index: -1
        text: index >= 0 && index < store.notes.length ? "Delete “" + store.notes[index].title + "”?" : ""
        informativeText: "You can't undo this."
        buttons: MessageDialog.Ok | MessageDialog.Cancel
        onAccepted: store.remove(index)
    }

    // A note's right-click menu, built by Hyprmux like other apps' menus.
    NativeMenu {
        id: noteMenu
        property int index: -1
        NativeMenuItem { text: "Open in Window"; shortcut: "Ctrl+Shift+N"; onTriggered: window.openWindow(store.notes[noteMenu.index]) }
        NativeMenuItem { text: "Export…"; onTriggered: exportDialog.exportNote(noteMenu.index) }
        NativeMenuSeparator {}
        NativeMenuItem { text: "Delete…"; onTriggered: { confirmDelete.index = noteMenu.index; confirmDelete.open() } }
    }

    RowLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 12

        ColumnLayout {
            Layout.preferredWidth: 240
            Layout.fillWidth: false   // a layout fills when a child does, unless told
            Layout.fillHeight: true
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                Button { Layout.fillWidth: true; text: "New"; onClicked: store.add() }
                Button { Layout.fillWidth: true; text: "Import…"; onClicked: importDialog.open() }
                Button {
                    Layout.fillWidth: true
                    text: "Export…"
                    enabled: store.current >= 0
                    onClicked: exportDialog.exportNote(store.current)
                }
            }
            ListView {
                id: list
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: store.notes
                currentIndex: store.current
                delegate: ItemDelegate {
                    id: row
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    text: modelData.title
                    highlighted: index === store.current
                    onClicked: store.current = index
                    TapHandler {
                        acceptedButtons: Qt.RightButton
                        onTapped: {
                            store.current = row.index
                            noteMenu.index = row.index
                            noteMenu.popup()
                        }
                    }
                }
            }
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            TextArea {
                id: editor
                placeholderText: store.current < 0 ? "⌘N makes a note" : "Write here"
                enabled: store.current >= 0
                wrapMode: TextArea.Wrap
                font.pixelSize: 14
                // Follows the selected note; typing writes it back.
                text: store.current >= 0 ? store.notes[store.current].body : ""
                onTextChanged: if (activeFocus && store.current >= 0 && text !== store.notes[store.current].body) store.update(text)
                Component.onCompleted: forceActiveFocus()

                // A trackpad pinch zooms the text.
                PinchHandler {
                    target: null
                    property real base: 14
                    onActiveChanged: if (active) base = editor.font.pixelSize
                    onActiveScaleChanged: editor.font.pixelSize = Math.round(Math.max(9, Math.min(40, base * activeScale)))
                }
            }
        }
    }

    // One note in a tile of its own, read-only. Its restore token names the note.
    Component {
        id: noteWindow
        HyprmuxWindow {
            id: single
            property var noteId
            readonly property var note: store.find(noteId)
            title: note ? note.title : "Note"
            restoreToken: "note:" + noteId
            ScrollView {
                anchors.fill: parent
                anchors.margins: 12
                TextArea { text: single.note ? single.note.body : ""; readOnly: true; wrapMode: TextArea.Wrap }
            }
        }
    }
}
