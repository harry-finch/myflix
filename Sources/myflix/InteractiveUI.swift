import Foundation
import Darwin

private struct SearchResult: Decodable {
    let show: ShowResponse
}

private struct ShowState {
    let tracked: TrackedShow
    let episodes: [Episode]?
    let status: String?
    let error: String?
}

private enum View {
    case dashboard, upcoming, all, details, search
}

/// A small terminal interface which shares the CLI's models and local data format.
struct InteractiveUI {
    private var view: View = .dashboard
    private var activeFilter: View = .dashboard
    private var showingArchived = false
    private var shows: [Int: TrackedShow] = [:]
    private var states: [ShowState] = []
    private var results: [ShowResponse] = []
    private var selected = 0
    private var detailID: Int?
    private var message = ""
    private var query = ""
    private var searchEditing = false
    private var storageError: String?
    private var pendingDeletion: TrackedShow?
    private var loadingProgress: (completed: Int, total: Int)?

    static func run() async {
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            fputs("Interactive mode requires a terminal.\n", stderr)
            return
        }
        // wcwidth needs the user’s locale to measure accented and wide characters.
        _ = setlocale(LC_CTYPE, "")
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            fputs("Could not read terminal settings.\n", stderr)
            return
        }
        var raw = original
        cfmakeraw(&raw)
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
        writeTerminal("\u{1B}[?1049h\u{1B}[?25l")
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            writeTerminal("\u{1B}[?25h\u{1B}[?1049l")
        }
        var ui = InteractiveUI()
        await ui.start()
    }

    private static func writeTerminal(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private mutating func start() async {
        load()
        await refresh()
        while true {
            render()
            guard let key = readKey() else { break }
            if key == "\u{3}" { break }
            if let show = pendingDeletion {
                switch key.lowercased() {
                case "o", "y":
                    var updated = shows
                    updated.removeValue(forKey: show.id)
                    pendingDeletion = nil
                    if save(updated) {
                        states.removeAll { $0.tracked.id == show.id }
                        if view == .details { view = activeFilter; detailID = nil }
                        selected = min(selected, max(0, itemCount - 1))
                        message = "\(show.name) a été retirée du suivi."
                    }
                case "n", "\u{1B}":
                    pendingDeletion = nil
                    message = "Suppression annulée."
                default: break
                }
                continue
            }
            if searchEditing {
                if key == "\r" || key == "\n" {
                    searchEditing = false
                    await search()
                } else if key == "\u{1B}" {
                    searchEditing = false
                    view = activeFilter
                    selected = 0
                } else if key == "\u{7F}" || key == "\u{8}" {
                    if !query.isEmpty { query.removeLast() }
                } else if key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                    query += key
                }
                continue
            }
            switch key {
            case "q": return
            case "\u{1B}[A", "k": selected = max(0, selected - 1)
            case "\u{1B}[B", "j": selected = min(max(0, itemCount - 1), selected + 1)
            case "1", "2", "3":
                let filter: View = key == "1" ? .dashboard : key == "2" ? .upcoming : .all
                activeFilter = filter
                if view != .details { view = filter }
                selected = 0
                message = ""
            case "a", "/": view = .search; selected = 0; query = ""; results = []; searchEditing = true; message = ""
            case "\u{1B}", "b":
                view = activeFilter
                selected = visibleShows.firstIndex { $0.tracked.id == detailID } ?? 0
                message = ""
            case "r": await refresh()
            case "\r", "\n":
                if view == .search { await addSelected() }
                else if view != .details, let state = selectedShow {
                    detailID = state.tracked.id; view = .details; selected = 0; message = ""
                }
            case "v" where view != .search && view != .details:
                showingArchived.toggle()
                selected = 0
                message = ""
                let loadedIDs = Set(states.map { $0.tracked.id })
                if shows.values.contains(where: { ($0.archived == true) == showingArchived && !loadedIDs.contains($0.id) }) {
                    await refresh()
                }
                if message.isEmpty {
                    message = showingArchived ? "Archives : 3 pour afficher toutes les séries archivées." : "Séries actives."
                }
            case "x" where view != .search && view != .details:
                if let state = selectedShow, var show = shows[state.tracked.id] {
                    show.archived = showingArchived ? nil : true
                    var updated = shows
                    updated[show.id] = show
                    if save(updated) {
                        if let index = states.firstIndex(where: { $0.tracked.id == show.id }) {
                            states[index] = ShowState(tracked: show, episodes: state.episodes, status: state.status, error: state.error)
                        }
                        selected = min(selected, max(0, itemCount - 1))
                        message = showingArchived ? "\(show.name) a été restaurée." : "\(show.name) a été archivée."
                    }
                }
            case "d" where view != .search:
                if let show = (view == .details ? detailState : selectedShow)?.tracked {
                    pendingDeletion = show
                    message = "Supprimer \(show.name) du suivi ?"
                }
            case "m":
                if view == .details, let episode = selectedEpisode, !episode.formattedLabel.isEmpty {
                    if let date = episode.airdate, !date.isEmpty, date <= today {
                        await updateProgress(episode.formattedLabel)
                    } else { message = "Cet épisode n'a pas encore été diffusé." }
                }
            case "u" where view != .search:
                if let state = view == .details ? detailState : selectedShow,
                   let episode = airedEpisodes(state).last, !episode.formattedLabel.isEmpty {
                    detailID = state.tracked.id
                    await updateProgress(episode.formattedLabel)
                } else { message = "Aucun épisode diffusé disponible." }
            default: break
            }
        }
    }

    private var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private mutating func load() {
        let url = TrackerManager.shared.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { shows = [:]; return }
        do { shows = try JSONDecoder().decode([Int: TrackedShow].self, from: Data(contentsOf: url)) }
        catch { storageError = "Lecture du suivi impossible : \(error.localizedDescription)" }
    }

    private mutating func save(_ updated: [Int: TrackedShow]) -> Bool {
        if let storageError { message = storageError; return false }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(updated).write(to: TrackerManager.shared.fileURL, options: .atomic)
            shows = updated
            return true
        } catch { message = "Enregistrement impossible : \(error.localizedDescription)"; return false }
    }

    private mutating func refresh() async {
        let tracked = shows.values.filter { ($0.archived == true) == showingArchived }
        loadingProgress = (0, tracked.count)
        message = ""
        render()
        var loaded: [ShowState] = []
        await withTaskGroup(of: ShowState.self) { group in
            for show in tracked {
                group.addTask {
                    do {
                        guard let data = try await API.getShowByID(id: show.id) else {
                            return ShowState(tracked: show, episodes: nil, status: nil, error: "TVmaze indisponible")
                        }
                        return ShowState(tracked: show, episodes: data._embedded?.episodes ?? [], status: data.status, error: nil)
                    } catch { return ShowState(tracked: show, episodes: nil, status: nil, error: error.localizedDescription) }
                }
            }
            for await state in group {
                loaded.append(state)
                loadingProgress = (loaded.count, tracked.count)
                render()
            }
        }
        states.removeAll { ($0.tracked.archived == true) == showingArchived }
        states.append(contentsOf: loaded)
        states.sort { $0.tracked.name.localizedCaseInsensitiveCompare($1.tracked.name) == .orderedAscending }
        loadingProgress = nil
        selected = min(selected, max(0, itemCount - 1))
        message = storageError ?? (loaded.contains { $0.error != nil } ? "Certaines séries n'ont pas pu être chargées. r : réessayer" : "")
    }

    private func airedEpisodes(_ state: ShowState) -> [Episode] {
        (state.episodes ?? []).filter { episode in
            guard let date = episode.airdate, !date.isEmpty else { return false }
            return date <= today && episode.season != nil && episode.number != nil
        }.sorted { ($0.season!, $0.number!) < ($1.season!, $1.number!) }
    }

    private func unwatched(_ state: ShowState) -> [Episode] {
        let watched = state.tracked.watchedEpisode.flatMap { myflix.parseEpisodeString($0) }
        return airedEpisodes(state).filter { ep in
            guard let watched else { return true }
            return (ep.season!, ep.number!) > watched
        }
    }

    private var visibleShows: [ShowState] {
        let scope = states.filter { ($0.tracked.archived == true) == showingArchived }
        switch view {
        case .dashboard: return scope.filter { $0.error != nil || !unwatched($0).isEmpty }
        case .upcoming: return scope.filter { $0.error != nil || !upcoming($0).isEmpty }
        default: return scope
        }
    }

    private func statusLabel(_ status: String?) -> String {
        switch status {
        case "Running": return "En cours"
        case "Ended": return "Terminée"
        case "To Be Determined": return "Incertaine"
        case "In Development": return "En développement"
        default: return "Statut inconnu"
        }
    }

    private func upcoming(_ state: ShowState) -> [Episode] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let end = formatter.string(from: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date())
        return (state.episodes ?? []).filter { ep in
            guard let date = ep.airdate, !date.isEmpty else { return false }
            return date > today && date <= end
        }.sorted { ($0.airdate ?? "") < ($1.airdate ?? "") }
    }

    private var detailState: ShowState? { states.first { $0.tracked.id == detailID } }
    private var selectedShow: ShowState? { visibleShows.indices.contains(selected) ? visibleShows[selected] : nil }
    private var detailEpisodes: [Episode] {
        guard let state = detailState else { return [] }
        switch activeFilter {
        case .upcoming: return upcoming(state)
        case .all:
            return (state.episodes ?? []).sorted {
                ($0.season ?? 0, $0.number ?? 0, $0.id ?? 0) < ($1.season ?? 0, $1.number ?? 0, $1.id ?? 0)
            }
        default:
            let watched = state.tracked.watchedEpisode.flatMap { myflix.parseEpisodeString($0) }
            return (state.episodes ?? []).filter { episode in
                guard let season = episode.season, let number = episode.number else { return false }
                guard let watched else { return true }
                return (season, number) > watched
            }.sorted { ($0.season!, $0.number!) < ($1.season!, $1.number!) }
        }
    }
    private var selectedEpisode: Episode? { detailEpisodes.indices.contains(selected) ? detailEpisodes[selected] : nil }
    private var itemCount: Int {
        switch view { case .details: return detailEpisodes.count; case .search: return results.count; default: return visibleShows.count }
    }

    private mutating func updateProgress(_ episode: String) async {
        guard let id = detailID, var show = shows[id] else { return }
        show.watchedEpisode = episode
        var updated = shows
        updated[id] = show
        guard save(updated) else { return }
        await refresh()
        message = "\(show.name) : progression enregistrée jusqu'à \(episode)."
    }

    private mutating func search() async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { message = "Saisis un titre."; searchEditing = true; return }
        message = "Recherche…"; render()
        do {
            var components = URLComponents(string: "https://api.tvmaze.com/search/shows")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            results = try JSONDecoder().decode([SearchResult].self, from: data).map(\.show)
            selected = 0
            message = results.isEmpty ? "Aucun résultat. / : nouvelle recherche" : "Entrée : ajouter la série sélectionnée"
        } catch { results = []; message = "Recherche impossible : \(error.localizedDescription)" }
    }

    private mutating func addSelected() async {
        guard results.indices.contains(selected) else { return }
        let show = results[selected]
        guard shows[show.id] == nil else { message = "Cette série est déjà suivie."; return }
        var updated = shows
        updated[show.id] = TrackedShow(id: show.id, name: show.name, watchedEpisode: nil)
        guard save(updated) else { return }
        showingArchived = false
        view = activeFilter; selected = 0
        await refresh()
        if let index = visibleShows.firstIndex(where: { $0.tracked.id == show.id }) { selected = index }
        message = "\(show.name) a été ajoutée."
    }

    private func readKey() -> String? {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        if byte == 27 {
            var pollFD = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&pollFD, 1, 40) > 0 {
                var seq = [byte]
                for _ in 0..<2 {
                    guard read(STDIN_FILENO, &byte, 1) == 1 else { break }
                    seq.append(byte)
                }
                return String(decoding: seq, as: UTF8.self)
            }
            return "\u{1B}"
        }
        var bytes = [byte]
        let extra = byte >= 0xF0 ? 3 : byte >= 0xE0 ? 2 : byte >= 0xC0 ? 1 : 0
        for _ in 0..<extra { if read(STDIN_FILENO, &byte, 1) == 1 { bytes.append(byte) } }
        return String(decoding: bytes, as: UTF8.self)
    }

    // Keep styling separate from the text so clipping uses terminal cell widths,
    // rather than counting invisible ANSI escape sequences as characters.
    private struct Span {
        let text: String
        let style: String
        init(_ text: String, _ style: String = "") { self.text = text; self.style = style }
    }

    private func render() {
        var size = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        let width = size.ws_col == 0 ? 80 : Int(size.ws_col)
        let height = size.ws_row == 0 ? 24 : Int(size.ws_row)
        let lineWidth = max(1, width - 1) // Avoid wrapping at the terminal's last column.
        let color = ProcessInfo.processInfo.environment["NO_COLOR"] == nil
            && ProcessInfo.processInfo.environment["TERM"] != "dumb"
        let accent = "1;38;5;141"
        let muted = "38;5;245"
        let bright = "1;38;5;255"
        let green = "38;5;114"
        let amber = "38;5;221"
        let blue = "38;5;110"
        let selectedStyle = "48;5;236"

        func line(_ spans: [Span], selected: Bool = false) -> String {
            var output = ""
            var used = 0
            for span in spans {
                var clipped = ""
                for character in span.text {
                    let cells = character.unicodeScalars.reduce(0) { count, scalar in
                        count + max(0, Int(wcwidth(Int32(scalar.value))))
                    }
                    if used + cells > lineWidth { break }
                    clipped.append(character)
                    used += cells
                }
                guard !clipped.isEmpty else { continue }
                if color {
                    let codes = [selected ? selectedStyle : "", span.style].filter { !$0.isEmpty }.joined(separator: ";")
                    if !codes.isEmpty { output += "\u{1B}[\(codes)m" }
                    output += clipped + "\u{1B}[0m"
                } else { output += clipped }
                if used >= lineWidth { break }
            }
            if selected && color && used < lineWidth {
                output += "\u{1B}[\(selectedStyle)m" + String(repeating: " ", count: lineWidth - used) + "\u{1B}[0m"
            }
            return output
        }

        func cells(_ value: String) -> Int {
            value.unicodeScalars.reduce(0) { $0 + max(0, Int(wcwidth(Int32($1.value)))) }
        }
        func column(_ value: String, width: Int) -> String {
            guard width > 0 else { return "" }
            var result = ""
            var used = 0
            for character in value {
                let size = cells(String(character))
                if used + size > width { break }
                result.append(character)
                used += size
            }
            if cells(value) > width, width > 1 {
                while used >= width, let last = result.last {
                    used -= cells(String(last))
                    result.removeLast()
                }
                result += "…"
                used += 1
            }
            return result + String(repeating: " ", count: max(0, width - used))
        }
        let rule = line([Span("  " + String(repeating: "─", count: max(0, lineWidth - 4)), muted)])
        let activeTab = activeFilter
        func tab(_ number: String, _ title: String, _ tabView: View) -> Span {
            Span(" \(number) \(title) ", activeTab == tabView ? accent : muted)
        }
        // Use a compact wordmark when there is not enough room for the banner.
        let logoColor = "1;38;5;196"
        var header: [String]
        if lineWidth >= 42 && height >= 20 {
            header = [
                line([Span("  █▄ ▄█  █   █  █▀▀  █    █  █   █", logoColor)]),
                line([Span("  █ ▀ █   █▄█   █▀   █    █   █▄█ ", logoColor), Span("   ton carnet de séries", muted)]),
                line([Span("  █   █    █    █    █▄▄  █  █   █", logoColor)])
            ]
        } else {
            header = [line([Span("  MYFLIX", logoColor), Span("   /   ton carnet de séries", muted)])]
        }
        header += [
            "",
            line([Span("  "), tab("1", "À regarder", .dashboard), Span("  "),
                  tab("2", "À venir", .upcoming), Span("  "), tab("3", "Toutes", .all),
                  Span("    \(shows.count) suivie(s)", muted)]),
            rule,
            ""
        ]
        var rows: [[Span]] = []
        var childRows: [[[Span]]] = []
        var emptyMessage = ""
        switch view {
        case .details:
            header.append(line([Span("  \(detailState?.tracked.name ?? "Série")", bright),
                                Span("   ·   \(statusLabel(detailState?.status))", blue),
                                Span(detailState?.tracked.archived == true ? "   ·   Archivée" : "", muted)]))
            header.append(line([Span("  Progression  ", muted), Span(detailState?.tracked.watchedEpisode ?? "Aucun épisode vu", blue)]))
            header.append("")
            let episodes = detailEpisodes
            let watched = detailState?.tracked.watchedEpisode.flatMap { myflix.parseEpisodeString($0) }
            let episodeWidth = min(14, max(7, episodes.map { cells($0.formattedLabel) }.max() ?? 7))
            let titleWidth = max(0, lineWidth - 5 - 3 - episodeWidth - 2 - 2 - 10)
            rows = episodes.map { ep in
                let done: Bool
                if let watched, let season = ep.season, let number = ep.number {
                    done = (season, number) <= watched
                } else { done = false }
                let airdate = ep.airdate.flatMap { $0.isEmpty ? nil : $0 }
                let future = airdate.map { $0 > today } ?? false
                let symbol = future ? "◷  " : done ? "✓  " : airdate == nil ? "?  " : "○  "
                let statusColor = future ? blue : done ? green : airdate == nil ? muted : amber
                return [Span(symbol, statusColor),
                        Span(column(ep.formattedLabel.isEmpty ? "—" : ep.formattedLabel, width: episodeWidth) + "  ", future ? blue : done ? green : blue),
                        Span(column(ep.name, width: titleWidth), future ? blue : done ? muted : ""),
                        Span("  " + (airdate ?? "—"), future ? blue : muted)]
            }
            if detailState?.error != nil {
                emptyMessage = "Les épisodes n'ont pas pu être chargés."
            } else if activeFilter == .upcoming {
                emptyMessage = "Aucun épisode prévu dans les 7 prochains jours."
            } else if activeFilter == .all {
                emptyMessage = "Aucun épisode disponible."
            } else {
                emptyMessage = "Aucun épisode à regarder. Tu es à jour !"
            }
        case .search:
            header.append(line([Span("  Ajouter une série", bright)]))
            header.append(line([Span("  Recherche TVmaze  ", muted), Span(query + (searchEditing ? "_" : ""), blue)]))
            header.append("")
            rows = results.map { show in
                [Span(show.name, bright), Span("   ·   \(statusLabel(show.status))", blue), Span("   ·   TVmaze #\(show.id)", muted),
                 Span(shows[show.id] == nil ? "" : "   ·   déjà suivie", green)]
            }
            emptyMessage = searchEditing ? "Saisis un titre puis appuie sur Entrée." : ""
        default:
            let title = view == .dashboard ? "À regarder" : view == .upcoming ? "À venir" : "Toutes les séries"
            let subtitle = view == .dashboard ? "Les épisodes diffusés qu'il te reste à découvrir." :
                view == .upcoming ? "Les sorties prévues dans les 7 prochains jours." : "Ta collection de séries suivies."
            header.append(line([Span(showingArchived ? "  Archives · \(title)" : "  \(title)", bright)]))
            header.append(line([Span("  \(subtitle)", muted)]))
            header.append("")
            let nameWidth = min(max(12, lineWidth - 52), max(12, visibleShows.map { cells($0.tracked.name) }.max() ?? 12))
            let statusWidth = 16
            rows = visibleShows.map { state in
                let name = column(state.tracked.name, width: nameWidth)
                let status = Span("  " + column(statusLabel(state.status), width: statusWidth), blue)
                if state.error != nil {
                    return [Span("●  ", amber), Span(name, bright), status, Span("  données indisponibles", amber)]
                }
                if view == .upcoming {
                    let count = upcoming(state).count
                    return [Span("◷  ", blue), Span(name, bright), status,
                            Span("  \(count) épisode(s) à venir", blue)]
                }
                let count = unwatched(state).count
                return [Span("●  ", count == 0 ? green : amber), Span(name, bright), status,
                        Span(count == 0 ? "  À jour" : "  \(count) épisode(s) à regarder", count == 0 ? green : amber)]
            }
            let treeEpisodes = visibleShows.map { view == .upcoming ? upcoming($0) : unwatched($0) }
            let episodeWidth = min(14, max(7, treeEpisodes.flatMap { $0 }.map { cells($0.formattedLabel) }.max() ?? 7))
            let titleWidth = max(0, lineWidth - 5 - 5 - episodeWidth - 2 - 2 - 10)
            childRows = treeEpisodes.map { episodes in
                episodes.enumerated().map { index, ep in
                    let branch = index == episodes.count - 1 ? "  └─ " : "  ├─ "
                    return [Span(branch, muted), Span(column(ep.formattedLabel.isEmpty ? "—" : ep.formattedLabel, width: episodeWidth) + "  ", blue),
                            Span(column(ep.name, width: titleWidth), muted),
                            Span("  " + (ep.airdate ?? "—"), muted)]
                }
            }
            emptyMessage = showingArchived ? "Aucune série archivée dans ce filtre. 3 : toutes les archives." :
                shows.isEmpty ? "Aucune série suivie. Appuie sur a pour commencer." :
                view == .dashboard ? "Tout est à jour !" : "Rien à afficher pour le moment."
        }

        let footerHeight = height >= 12 ? 4 : 2
        // On narrow or short terminals, retain room for a selected row and controls.
        let headerLimit = max(0, height - footerHeight - 1)
        if header.count > headerLimit { header = Array(header.prefix(headerLimit)) }
        let room = max(1, height - header.count - footerHeight)
        // Child lines belong to a show, but never become keyboard selections.
        // Limit oversized groups to the viewport and indicate the remaining count.
        var displayRows: [(index: Int, selectable: Bool, spans: [Span])] = []
        var positions: [Int] = []
        for (index, row) in rows.enumerated() {
            positions.append(displayRows.count)
            displayRows.append((index, true, row))
            if childRows.indices.contains(index) {
                let children = childRows[index]
                let limit = room >= 3 ? room - 2 : max(0, room - 1)
                for child in children.prefix(limit) {
                    displayRows.append((index, false, child))
                }
                if children.count > limit && room >= 3 {
                    displayRows.append((index, false, [Span("  └─ … \(children.count - limit) autre(s) épisode(s) · Entrée pour voir la suite", muted)]))
                }
            }
        }
        let selectedPosition = positions.indices.contains(selected) ? positions[selected] : 0
        let selectedEnd = selected + 1 < positions.count ? positions[selected + 1] : displayRows.count
        let offset = selectedEnd > room ? selectedPosition : 0
        var lines = header
        if let progress = loadingProgress {
            let barWidth = max(1, min(20, lineWidth - 30))
            let filled = progress.total == 0 ? barWidth : barWidth * progress.completed / progress.total
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: barWidth - filled)
            lines.append(line([Span("  Chargement  [\(bar)]  \(progress.completed)/\(progress.total)", blue)]))
        } else if rows.isEmpty && !emptyMessage.isEmpty {
            lines.append(line([Span("  \(emptyMessage)", muted)]))
        } else {
            for item in displayRows.dropFirst(offset).prefix(room) {
                let isSelected = item.selectable && item.index == selected && !searchEditing
                let prefix = item.selectable ? (isSelected ? "  ❯  " : "     ") : "     "
                lines.append(line([Span(prefix, isSelected ? accent : muted)] + item.spans, selected: isSelected))
            }
        }
        while lines.count < height - footerHeight { lines.append("") }
        if footerHeight == 4 {
            lines.append(rule)
            lines.append(line([Span(message.isEmpty ? " " : "  \(message)", message.isEmpty ? muted : blue)]))
        }
        let keys: [Span]
        if let show = pendingDeletion {
            keys = [Span("  o", accent), Span(" oui   ", muted), Span("n", accent), Span(" non   ", muted), Span("Supprimer \(show.name) ?", amber)]
        } else if searchEditing {
            keys = [Span("  Entrée", accent), Span(" rechercher   ", muted), Span("Échap", accent), Span(" retour", muted)]
        } else if view == .search {
            keys = [Span("  ↑↓", accent), Span(" choisir   ", muted), Span("Entrée", accent), Span(" ajouter   ", muted), Span("/", accent), Span(" rechercher   ", muted), Span("q", accent), Span(" quitter", muted)]
        } else if view == .details {
            keys = [Span("  ↑↓", accent), Span(" naviguer   ", muted), Span("m", accent), Span(" vu jusqu'ici   ", muted), Span("d", accent), Span(" supprimer   ", muted), Span("u", accent), Span(" à jour   ", muted), Span("b", accent), Span(" retour   ", muted), Span("q", accent), Span(" quitter", muted)]
        } else {
            keys = [Span("  ↑↓", accent), Span(" naviguer  ", muted), Span("Entrée", accent), Span(" ouvrir  ", muted),
                    Span("x", accent), Span(showingArchived ? " restaurer  " : " archiver  ", muted),
                    Span("v", accent), Span(showingArchived ? " actives  " : " archives  ", muted),
                    Span("a", accent), Span(" ajouter  ", muted), Span("d", accent), Span(" supprimer  ", muted),
                    Span("u", accent), Span(" à jour  ", muted), Span("r", accent), Span(" actualiser  ", muted), Span("q", accent), Span(" quitter", muted)]
        }
        lines.append(line(keys))
        if footerHeight == 4 { lines.append("") }
        Self.writeTerminal("\u{1B}[H\u{1B}[2J" + lines.prefix(height).joined(separator: "\r\n"))
    }
}
