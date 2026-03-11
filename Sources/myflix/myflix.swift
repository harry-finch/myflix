import Foundation

struct ShowResponse: Codable {
    let id: Int
    let name: String
    let _embedded: Embedded?
}

struct Embedded: Codable {
    let previousepisode: Episode?
    let nextepisode: Episode?
    let episodes: [Episode]?
}

struct Episode: Codable {
    let id: Int?
    let name: String
    let airdate: String?
    let season: Int?
    let number: Int?
    
    var formattedLabel: String {
        if let s = season, let n = number {
            return String(format: "S%02dE%02d", s, n)
        }
        return ""
    }
}

// MARK: - Tracking Models

struct TrackedShow: Codable {
    let id: Int
    let name: String
    var watchedEpisode: String? // e.g., "S01E02"
}

struct TrackerManager {
    static let shared = TrackerManager()
    let fileURL: URL
    
    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        fileURL = homeDir.appendingPathComponent(".tvshow_tracker.json")
    }
    
    func loadShows() -> [Int: TrackedShow] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([Int: TrackedShow].self, from: data)) ?? [:]
    }
    
    func saveShows(_ shows: [Int: TrackedShow]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(shows) {
            try? data.write(to: fileURL)
        }
    }
}

enum Command {
    case add(String)
    case markUpToDate(String)
    case addAndMarkUpToDate(String)
    case markWatched(episode: String, show: String)
    case remove(String)
    case reset(String)
    case showDetails(query: String, showAllCurrentSeason: Bool)
    case dashboard
    case listTrackedShows
}

struct API {
    static func searchShow(query: String, embedEpisodes: Bool = false) async throws -> ShowResponse? {
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "embed[]", value: "previousepisode"),
            URLQueryItem(name: "embed[]", value: "nextepisode")
        ]
        
        if embedEpisodes {
            queryItems.append(URLQueryItem(name: "embed[]", value: "episodes"))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("TVshow CLI / 1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(ShowResponse.self, from: data)
    }
    
    static func getShowByID(id: Int) async throws -> ShowResponse? {
        let url = URL(string: "https://api.tvmaze.com/shows/\(id)?embed[]=episodes")!
        var request = URLRequest(url: url)
        request.setValue("TVshow CLI / 1.0", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(ShowResponse.self, from: data)
    }
}

@main
struct myflix {
    static func parseCommand() -> Command? {
        let args = Array(CommandLine.arguments.dropFirst())
        
        if args.isEmpty {
            return .dashboard
        }
        
        var showAllCurrentSeason = false
        var hasAdd = false
        var hasUpToDate = false
        var flag: String?
        var arg1: String?
        var varArgs: [String] = []
        
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-l", "--list":
                showAllCurrentSeason = true
            case "-a", "--add":
                hasAdd = true
                flag = arg
            case "-u":
                hasUpToDate = true
                flag = arg
            case "-r", "--reset":
                flag = arg
            case "-w":
                flag = arg
                if i + 1 < args.count {
                    arg1 = args[i+1]
                    i += 1
                } else {
                    print("Error: -w requires an episode number.")
                    return nil
                }
            default:
                varArgs.append(arg)
            }
            i += 1
        }
        
        let query = varArgs.joined(separator: " ")
        
        if flag != nil || hasAdd || hasUpToDate {
            if query.isEmpty {
                print("Error: Missing show name.")
                return nil
            }
            
            if hasAdd && hasUpToDate {
                return .addAndMarkUpToDate(query)
            } else if hasAdd {
                return .add(query)
            } else if hasUpToDate {
                return .markUpToDate(query)
            }
            
            switch flag {
            case "-w": return .markWatched(episode: arg1 ?? "", show: query)
            case "-r": return .remove(query)
            case "--reset": return .reset(query)
            default: break
            }
        }
        
        if query.isEmpty {
            if showAllCurrentSeason {
                return .listTrackedShows
            }
            return .dashboard
        }
        
        return .showDetails(query: query, showAllCurrentSeason: showAllCurrentSeason)
    }

    static func main() async {
        guard let command = parseCommand() else {
            print("Usage: myflix [flags] <show name>")
            print("Options:")
            print("  -l, --list Show all tracked shows. If a show name is provided, show all episodes from its current season")
            print("  -a, --add  Add a new show to track")
            print("  -u         Mark the show as up to date")
            print("  -w <ep>    Mark a specific episode and all preceding episodes as watched (e.g., S01E02)")
            print("  -r         Remove a show from tracking")
            print("  --reset    Reset watched episodes for a show")
            print("  (no args)  Dashboard: display all episodes left to watch")
            return
        }
        
        switch command {
        case .add(let query):
            await handleAdd(query)
        case .markUpToDate(let query):
            await handleMarkUpToDate(query)
        case .addAndMarkUpToDate(let query):
            await handleAddAndMarkUpToDate(query)
        case .markWatched(let episode, let query):
            await handleMarkWatched(episode: episode, query: query)
        case .remove(let query):
            handleRemove(query)
        case .reset(let query):
            handleReset(query)
        case .dashboard:
            await handleDashboard()
        case .showDetails(let query, let allSeason):
            await fetchAndPrintShow(query: query, showAllCurrentSeason: allSeason)
        case .listTrackedShows:
            handleListTrackedShows()
        }
    }
    
    static func findTrackedShowID(query: String, in shows: [Int: TrackedShow]) -> Int? {
        let q = query.lowercased()
        return shows.first(where: { $0.value.name.lowercased() == q })?.key ??
               shows.first(where: { $0.value.name.lowercased().contains(q) })?.key
    }

    static func parseEpisodeString(_ ep: String) -> (Int, Int)? {
        let upper = ep.uppercased()
        let pattern = "^S(\\d+)E(\\d+)$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: upper, options: [], range: NSRange(location: 0, length: upper.utf16.count)) {
            let nsString = upper as NSString
            let sStr = nsString.substring(with: match.range(at: 1))
            let eStr = nsString.substring(with: match.range(at: 2))
            if let s = Int(sStr), let e = Int(eStr) {
                return (s, e)
            }
        }
        return nil
    }

    static func formatEpisodeString(_ ep: String) -> String {
        if let parsed = parseEpisodeString(ep) {
            return String(format: "S%02dE%02d", parsed.0, parsed.1)
        }
        return ep.uppercased()
    }

    static func handleAdd(_ query: String) async {
        do {
            guard let show = try await API.searchShow(query: query) else {
                print("Show '\(query)' not found.")
                return
            }
            let manager = TrackerManager.shared
            var shows = manager.loadShows()
            
            if shows[show.id] != nil {
                print("'\(show.name)' is already being tracked.")
                return
            }
            
            shows[show.id] = TrackedShow(id: show.id, name: show.name, watchedEpisode: nil)
            manager.saveShows(shows)
            print("Started tracking '\(show.name)'.")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
    
    static func handleAddAndMarkUpToDate(_ query: String) async {
        do {
            guard let show = try await API.searchShow(query: query) else {
                print("Show '\(query)' not found.")
                return
            }
            let manager = TrackerManager.shared
            var shows = manager.loadShows()
            
            if shows[show.id] != nil {
                print("'\(show.name)' is already being tracked.")
            } else {
                shows[show.id] = TrackedShow(id: show.id, name: show.name, watchedEpisode: nil)
                print("Started tracking '\(show.name)'.")
            }
            
            if let prev = show._embedded?.previousepisode {
                let epLabel = prev.formattedLabel.isEmpty ? prev.name : prev.formattedLabel
                shows[show.id]?.watchedEpisode = epLabel
                manager.saveShows(shows)
                print("Marked '\(show.name)' as up to date (Last watched: \(epLabel)).")
            } else {
                manager.saveShows(shows)
                print("No aired episodes found for '\(show.name)'.")
            }
            
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
    
    static func handleMarkUpToDate(_ query: String) async {
        let manager = TrackerManager.shared
        var shows = manager.loadShows()
        
        guard let id = findTrackedShowID(query: query, in: shows) else {
            print("Could not find a tracked show matching '\(query)'. Make sure to add it first.")
            return
        }
        
        do {
            guard let showData = try await API.searchShow(query: shows[id]!.name) else {
                print("Could not find show on TVMaze.")
                return
            }
            if let prev = showData._embedded?.previousepisode {
                let epLabel = prev.formattedLabel.isEmpty ? prev.name : prev.formattedLabel
                shows[id]?.watchedEpisode = epLabel
                manager.saveShows(shows)
                print("Marked '\(showData.name)' as up to date (Last watched: \(epLabel)).")
            } else {
                print("No aired episodes found for '\(showData.name)'.")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
    
    static func handleMarkWatched(episode: String, query: String) async {
        let manager = TrackerManager.shared
        var shows = manager.loadShows()
        
        guard let id = findTrackedShowID(query: query, in: shows) else {
            print("Could not find a tracked show matching '\(query)'. Make sure to add it first.")
            return
        }
        
        let formattedEp = formatEpisodeString(episode)
        shows[id]?.watchedEpisode = formattedEp
        manager.saveShows(shows)
        print("Marked '\(shows[id]!.name)' episode \(formattedEp) as watched.")
    }
    
    static func handleRemove(_ query: String) {
        let manager = TrackerManager.shared
        var shows = manager.loadShows()
        
        if let id = findTrackedShowID(query: query, in: shows) {
            let name = shows[id]!.name
            shows.removeValue(forKey: id)
            manager.saveShows(shows)
            print("Stopped tracking '\(name)'.")
        } else {
            print("Could not find a tracked show matching '\(query)'.")
        }
    }
    
    static func handleReset(_ query: String) {
        let manager = TrackerManager.shared
        var shows = manager.loadShows()
        
        if let id = findTrackedShowID(query: query, in: shows) {
            shows[id]?.watchedEpisode = nil
            manager.saveShows(shows)
            print("Reset watched progress for '\(shows[id]!.name)'.")
        } else {
            print("Could not find a tracked show matching '\(query)'.")
        }
    }
    
    static func handleDashboard() async {
        let manager = TrackerManager.shared
        let shows = manager.loadShows()
        
        if shows.isEmpty {
            print("You are not tracking any shows. Use --add <show> to start.")
            return
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        
        var results = [(String, [Episode])]()
        
        print("Fetching data for tracked shows...\n")
        
        await withTaskGroup(of: (String, [Episode])?.self) { group in
            for (_, tracked) in shows {
                group.addTask {
                    guard let showData = try? await API.getShowByID(id: tracked.id) else { return nil }
                    let episodes = showData._embedded?.episodes ?? []
                    
                    let watchedParsed = tracked.watchedEpisode.flatMap { parseEpisodeString($0) }
                    
                    let unwatched = episodes.filter { ep in
                        // Must have an airdate and be <= today
                        guard let airdate = ep.airdate, !airdate.isEmpty else { return false }
                        guard airdate <= today else { return false }
                        
                        // Must be strictly after watched episode
                        if let w = watchedParsed, let es = ep.season, let en = ep.number {
                            if es > w.0 { return true }
                            if es == w.0 && en > w.1 { return true }
                            return false
                        }
                        
                        return true
                    }
                    
                    if !unwatched.isEmpty {
                        return (tracked.name, unwatched)
                    }
                    return nil
                }
            }
            
            for await result in group {
                if let r = result {
                    results.append(r)
                }
            }
        }
        
        if results.isEmpty {
            print("You are completely up to date! 🎉")
            return
        }
        
        results.sort { $0.0 < $1.0 }
        
        for (showName, episodes) in results {
            print("--- \(showName) (\(episodes.count) left) ---")
            let epsToPrint = episodes.prefix(5)
            for ep in epsToPrint {
                print("  \(ep.formattedLabel) - \(ep.name) (Aired: \(ep.airdate ?? "Unknown"))")
            }
            if episodes.count > 5 {
                print("  ... and \(episodes.count - 5) more episodes.")
            }
            print("")
        }
    }

    static func handleListTrackedShows() {
        let manager = TrackerManager.shared
        let shows = manager.loadShows()
        
        if shows.isEmpty {
            print("You are not tracking any shows. Use -a <show> or --add <show> to start.")
            return
        }
        
        print("Tracked Shows:")
        let sortedShows = shows.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for show in sortedShows {
            if let watched = show.watchedEpisode {
                print("  - \(show.name) (Watched up to: \(watched))")
            } else {
                print("  - \(show.name) (No episodes watched yet)")
            }
        }
    }

    static func fetchAndPrintShow(query: String, showAllCurrentSeason: Bool) async {
        
        if query.isEmpty {
            print("Error: Missing show name.")
            return
        }
        
        var components = URLComponents(string: "https://api.tvmaze.com/singlesearch/shows")!
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "embed[]", value: "previousepisode"),
            URLQueryItem(name: "embed[]", value: "nextepisode")
        ]
        
        if showAllCurrentSeason {
            queryItems.append(URLQueryItem(name: "embed[]", value: "episodes"))
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            print("Error: Invalid URL.")
            return
        }
        
        do {
            var request = URLRequest(url: url)
            request.setValue("TVshow CLI / 1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("Error: Invalid response from server.")
                return
            }
            
            if httpResponse.statusCode == 404 {
                print("Show '\(query)' not found.")
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                print("Error: Server returned status code \(httpResponse.statusCode).")
                return
            }
            
            let decoder = JSONDecoder()
            let show = try decoder.decode(ShowResponse.self, from: data)
            
            print("Show: \(show.name)")
            
            let previous = show._embedded?.previousepisode
            let next = show._embedded?.nextepisode
            
            if !showAllCurrentSeason {
                if let prev = previous {
                    let label = prev.formattedLabel.isEmpty ? "" : "[\(prev.formattedLabel)] "
                    print("Last episode: \(label)'\(prev.name)' aired on \(prev.airdate ?? "Unknown")")
                } else {
                    print("Last episode: N/A")
                }
                
                if let nxt = next {
                    let label = nxt.formattedLabel.isEmpty ? "" : "[\(nxt.formattedLabel)] "
                    print("Next episode: \(label)'\(nxt.name)' airs on \(nxt.airdate ?? "Unknown")")
                } else {
                    print("Next episode: N/A / TBA")
                }
            } else {
                // Feature -a logic
                let currentSeason = next?.season ?? previous?.season
                guard let seasonToDisplay = currentSeason else {
                    print("No season information available for this show.")
                    return
                }
                
                guard let episodes = show._embedded?.episodes else {
                    print("No episode list available.")
                    return
                }
                
                let seasonEpisodes = episodes.filter { $0.season == seasonToDisplay }.sorted {
                    ($0.number ?? 0) < ($1.number ?? 0)
                }
                
                print("\n--- Season \(seasonToDisplay) Episodes ---")
                
                for episode in seasonEpisodes {
                    let isLastAired = (episode.id != nil && episode.id == previous?.id)
                    let label = episode.formattedLabel
                    let dateStr = episode.airdate ?? "TBA"
                    
                    var line = " \(label) - \(episode.name) (Airs: \(dateStr))"
                    
                    if isLastAired {
                        // Highlight in green and bold
                        let greenBold = "\u{001B}[1;32m"
                        let reset = "\u{001B}[0m"
                        line = "\(greenBold)\(line) <== LAST AIRED\(reset)"
                    }
                    
                    print(line)
                }
                print("---------------------------\n")
            }
            
        } catch {
            print("Error: Failed to fetch data. \(error.localizedDescription)")
        }
    }
}
