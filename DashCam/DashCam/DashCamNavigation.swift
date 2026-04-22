//
//  DashCamNavigation.swift
//  DashCam
//
//  Created by OpenAI Codex on 4/13/26.
//

import SwiftUI
import MapKit
import CoreLocation
import Combine

enum DashNavigationCameraMode {
    case forward
    case overview

    var label: String {
        switch self {
        case .forward:
            return "Forward"
        case .overview:
            return "Overview"
        }
    }

    var symbolName: String {
        switch self {
        case .forward:
            return "location.north.line.fill"
        case .overview:
            return "map.fill"
        }
    }
}

private struct DashCodableCoordinate: Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    nonisolated var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct DashStoredDestination: Codable {
    let title: String
    let subtitle: String
    let coordinate: DashCodableCoordinate
    let savedAt: Date
}

private struct DashStoredDriveEntry: Codable {
    let id: String
    let startedAt: Date
    var endedAt: Date
    var distanceMeters: CLLocationDistance
    var coordinates: [DashCodableCoordinate]
}

private struct DashRouteHistoryState: Codable {
    var destinations: [DashStoredDestination]
    var drives: [DashStoredDriveEntry]
}

struct DashRecentDestination: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let savedAt: Date

    nonisolated fileprivate init(stored: DashStoredDestination) {
        title = stored.title
        subtitle = stored.subtitle
        coordinate = stored.coordinate.coordinate
        savedAt = stored.savedAt
        id = "\(title)|\(subtitle)|\(savedAt.timeIntervalSince1970)"
    }

    var timeText: String {
        Self.dateFormatter.string(from: savedAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

struct DashDriveHistoryEntry: Identifiable {
    let id: String
    let startedAt: Date
    let endedAt: Date
    let distanceMeters: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]

    nonisolated fileprivate init(stored: DashStoredDriveEntry) {
        id = stored.id
        startedAt = stored.startedAt
        endedAt = stored.endedAt
        distanceMeters = stored.distanceMeters
        coordinates = stored.coordinates.map(\.coordinate)
    }

    var durationText: String {
        Self.durationFormatter.string(from: endedAt.timeIntervalSince(startedAt)) ?? "Drive"
    }

    var distanceText: String {
        DashNavigationRoute.formatDistance(distanceMeters)
    }

    var titleText: String {
        if Calendar.current.isDateInToday(startedAt) {
            return "Today • \(Self.timeFormatter.string(from: startedAt))"
        }
        if Calendar.current.isDateInYesterday(startedAt) {
            return "Yesterday • \(Self.timeFormatter.string(from: startedAt))"
        }
        return "\(Self.dayFormatter.string(from: startedAt)) • \(Self.timeFormatter.string(from: startedAt))"
    }

    var subtitleText: String {
        "\(distanceText) • \(durationText)"
    }

    var cameraRect: MKMapRect {
        guard let first = coordinates.first else { return .world }

        let rect = coordinates.dropFirst().reduce(MKMapRect(centeredAt: first, meters: 400)) { partialRect, coordinate in
            partialRect.union(MKMapRect(centeredAt: coordinate, meters: 220))
        }

        return rect.insetBy(dx: -rect.size.width * 0.18, dy: -rect.size.height * 0.18)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

struct DashDriveHistoryDaySection: Identifiable {
    let day: Date
    let entries: [DashDriveHistoryEntry]

    var id: Date { day }

    var title: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: day)
    }
}

private final class DashRouteHistoryStore {
    private let maxDestinations = 20
    private let maxDriveDays = 14
    private let maxDriveEntries = 80
    private let minDrivePointDistance: CLLocationDistance = 28
    private let newDriveGap: TimeInterval = 8 * 60
    private let newDriveJumpDistance: CLLocationDistance = 650
    private let persistenceQueue = DispatchQueue(label: "dashcam.route.history.persistence", qos: .utility)
    private let drivePersistenceDelay: TimeInterval = 1.5

    private var state = DashRouteHistoryState(destinations: [], drives: [])
    private var pendingPersistWorkItem: DispatchWorkItem?

    init() {
        load()
    }

    var recentDestinations: [DashRecentDestination] {
        state.destinations
            .sorted { $0.savedAt > $1.savedAt }
            .map(DashRecentDestination.init)
    }

    var driveEntries: [DashDriveHistoryEntry] {
        state.drives
            .sorted { $0.startedAt > $1.startedAt }
            .map(DashDriveHistoryEntry.init)
    }

    func recordDestination(_ destination: MKMapItem) {
        let title = destination.name ?? "Destination"
        let subtitle = destination.placemark.title ?? ""
        let coordinate = DashCodableCoordinate(destination.placemark.coordinate)

        state.destinations.removeAll {
            $0.title == title &&
            $0.subtitle == subtitle &&
            $0.coordinate == coordinate
        }

        state.destinations.insert(
            DashStoredDestination(
                title: title,
                subtitle: subtitle,
                coordinate: coordinate,
                savedAt: Date()
            ),
            at: 0
        )
        if state.destinations.count > maxDestinations {
            state.destinations.removeLast(state.destinations.count - maxDestinations)
        }

        persistNow()
    }

    func recordDriveLocation(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 80 else { return }

        let coordinate = DashCodableCoordinate(location.coordinate)

        if let lastIndex = state.drives.indices.last {
            var lastEntry = state.drives[lastIndex]
            let lastCoordinate = lastEntry.coordinates.last?.coordinate
            let lastLocation = lastCoordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            let timeGap = location.timestamp.timeIntervalSince(lastEntry.endedAt)
            let jumpDistance = lastLocation.map { location.distance(from: $0) } ?? 0

            if Calendar.current.isDate(lastEntry.startedAt, inSameDayAs: location.timestamp),
               timeGap < newDriveGap,
               jumpDistance < newDriveJumpDistance {
                guard lastLocation == nil || jumpDistance >= minDrivePointDistance else { return }

                lastEntry.coordinates.append(coordinate)
                lastEntry.endedAt = location.timestamp
                lastEntry.distanceMeters += max(jumpDistance, 0)
                state.drives[lastIndex] = lastEntry
                trimDriveHistory()
                scheduleDrivePersistence()
                return
            }
        }

        state.drives.append(
            DashStoredDriveEntry(
                id: UUID().uuidString,
                startedAt: location.timestamp,
                endedAt: location.timestamp,
                distanceMeters: 0,
                coordinates: [coordinate]
            )
        )
        trimDriveHistory()
        scheduleDrivePersistence()
    }

    private func trimDriveHistory() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -maxDriveDays, to: Date()) ?? .distantPast
        state.drives.removeAll { $0.endedAt < cutoff }

        if state.drives.count > maxDriveEntries {
            state.drives.removeFirst(state.drives.count - maxDriveEntries)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode(DashRouteHistoryState.self, from: data) else {
            return
        }
        state = decoded
        trimDriveHistory()
    }

    private func persist(_ snapshot: DashRouteHistoryState) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = historyURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        // Route history is effectively a breadcrumb trail of where the driver
        // has been. Treat it as high-sensitivity private data every time we
        // rewrite the file so backup and protection attributes stay intact.
        try? DashCamController.applyRouteHistoryProtection(to: url)
    }

    private func persistNow() {
        pendingPersistWorkItem?.cancel()
        pendingPersistWorkItem = nil
        let snapshot = state
        persistenceQueue.async {
            self.persist(snapshot)
        }
    }

    private func scheduleDrivePersistence() {
        pendingPersistWorkItem?.cancel()
        let snapshot = state
        let workItem = DispatchWorkItem { [weak self] in
            self?.persist(snapshot)
        }
        pendingPersistWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + drivePersistenceDelay, execute: workItem)
    }

    deinit {
        pendingPersistWorkItem?.cancel()
        persist(state)
    }

    private var historyURL: URL {
        // Reuse the controller's storage helper so route history and saved media
        // share the same documented storage policy instead of drifting apart.
        (try? DashCamController.routeHistoryFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("route-history.json")
    }
}

struct DashNavigationStep: Identifiable {
    let id = UUID()
    let instructions: String
    let distanceMeters: CLLocationDistance
    let coordinates: [CLLocationCoordinate2D]
    let endCoordinate: CLLocationCoordinate2D

    init?(routeStep: MKRoute.Step, fallbackEndCoordinate: CLLocationCoordinate2D? = nil, isFinalStep: Bool = false) {
        let trimmedInstructions = routeStep.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinates = routeStep.polyline.coordinates

        guard let endCoordinate = coordinates.last ?? fallbackEndCoordinate else { return nil }
        guard !trimmedInstructions.isEmpty || !coordinates.isEmpty || routeStep.distance > 0 || isFinalStep else { return nil }

        instructions = trimmedInstructions.isEmpty ? (isFinalStep ? "Arrive at your destination" : "Continue") : trimmedInstructions
        distanceMeters = max(routeStep.distance, 0)
        self.coordinates = coordinates
        self.endCoordinate = endCoordinate
    }

    var symbolName: String {
        let normalized = instructions.lowercased()

        if normalized.contains("destination") || normalized.contains("arrive") {
            return "flag.checkered"
        }
        if normalized.contains("u-turn") {
            return normalized.contains("right") ? "arrow.uturn.right" : "arrow.uturn.left"
        }
        if normalized.contains("left") {
            return "arrow.turn.up.left"
        }
        if normalized.contains("right") {
            return "arrow.turn.up.right"
        }
        if normalized.contains("merge") {
            return "arrow.up.right"
        }
        if normalized.contains("roundabout") || normalized.contains("traffic circle") {
            return "arrow.clockwise.circle"
        }

        return "arrow.up"
    }

    var distanceText: String {
        DashNavigationRoute.formatDistance(distanceMeters)
    }

    func heading(from currentCoordinate: CLLocationCoordinate2D) -> CLLocationDirection {
        guard !coordinates.isEmpty else {
            return currentCoordinate.bearing(to: endCoordinate)
        }

        let currentPoint = MKMapPoint(currentCoordinate)
        let nearestIndex = coordinates.indices.min { lhs, rhs in
            currentPoint.distance(to: MKMapPoint(coordinates[lhs])) <
            currentPoint.distance(to: MKMapPoint(coordinates[rhs]))
        } ?? 0

        let lookAheadIndex = min(nearestIndex + 3, coordinates.count - 1)
        let lookAheadCoordinate = coordinates[lookAheadIndex]
        return currentCoordinate.bearing(to: lookAheadCoordinate)
    }
}

struct DashNavigationRoute: Identifiable {
    let id = UUID()
    let destinationTitle: String
    let destinationSubtitle: String
    let destinationCoordinate: CLLocationCoordinate2D
    let routeCoordinates: [CLLocationCoordinate2D]
    let steps: [DashNavigationStep]
    let expectedTravelTime: TimeInterval
    let distanceMeters: CLLocationDistance
    let cameraRect: MKMapRect

    init(destination: MKMapItem, route: MKRoute, origin: CLLocationCoordinate2D) {
        let destinationCoordinate = destination.placemark.coordinate
        let builtSteps = route.steps.enumerated().compactMap { index, routeStep in
            DashNavigationStep(
                routeStep: routeStep,
                fallbackEndCoordinate: destinationCoordinate,
                isFinalStep: index == route.steps.count - 1
            )
        }

        destinationTitle = destination.name ?? "Destination"
        destinationSubtitle = destination.placemark.title ?? ""
        self.destinationCoordinate = destinationCoordinate
        routeCoordinates = route.polyline.coordinates
        steps = builtSteps
        expectedTravelTime = route.expectedTravelTime
        distanceMeters = route.distance
        cameraRect = DashNavigationRoute.makeCameraRect(
            for: route,
            origin: origin,
            destination: destinationCoordinate
        )
    }

    var summaryText: String {
        "Route • \(travelTimeText) • \(distanceText)"
    }

    var destinationLine: String {
        destinationSubtitle.isEmpty ? destinationTitle : "\(destinationTitle) • \(destinationSubtitle)"
    }

    var travelTimeText: String {
        Self.travelTimeFormatter.string(from: expectedTravelTime) ?? "\(max(Int(expectedTravelTime / 60), 1)) min"
    }

    var distanceText: String {
        Self.formatDistance(distanceMeters)
    }

    var arrivalTimeText: String {
        Self.arrivalFormatter.string(from: Date().addingTimeInterval(expectedTravelTime))
    }

    private static let travelTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let arrivalFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    static func formatDistance(_ meters: CLLocationDistance?) -> String {
        guard let meters else { return "--" }

        if meters < 402.336 {
            let roundedFeet = max(Int((meters * 3.28084 / 50).rounded() * 50), 50)
            return "\(roundedFeet) ft"
        }

        let miles = meters / 1_609.344
        return miles >= 10 ? String(format: "%.0f mi", miles) : String(format: "%.1f mi", miles)
    }

    private static func makeCameraRect(
        for route: MKRoute,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> MKMapRect {
        let averageLatitude = (origin.latitude + destination.latitude) / 2
        let paddingMeters = max(route.distance * 0.18, 500)
        let paddingPoints = paddingMeters * MKMapPointsPerMeterAtLatitude(averageLatitude)

        return route.polyline.boundingMapRect
            .union(MKMapRect(centeredAt: origin))
            .union(MKMapRect(centeredAt: destination))
            .insetBy(dx: -paddingPoints, dy: -paddingPoints)
    }
}

struct DashNavigationCompletion: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    fileprivate let result: MKLocalSearchCompletion

    init(result: MKLocalSearchCompletion) {
        self.result = result
        title = result.title
        subtitle = result.subtitle
    }
}

final class DashNavigationModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var searchText: String = ""
    @Published private(set) var completions: [DashNavigationCompletion] = []
    @Published private(set) var activeRoute: DashNavigationRoute?
    @Published private(set) var selectedDriveHistory: DashDriveHistoryEntry?
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var distanceToCurrentStepMeters: CLLocationDistance?
    @Published private(set) var distanceToDestinationMeters: CLLocationDistance?
    @Published private(set) var isSearching: Bool = false
    @Published private(set) var isCalculatingRoute: Bool = false
    @Published private(set) var didArrive: Bool = false
    @Published private(set) var lockedCameraHeading: CLLocationDirection?
    @Published private(set) var errorMessage: String = ""
    @Published var cameraMode: DashNavigationCameraMode = .forward
    @Published private(set) var recentDestinations: [DashRecentDestination] = []
    @Published private(set) var driveHistory: [DashDriveHistoryEntry] = []

    private let completer = MKLocalSearchCompleter()
    private let historyStore = DashRouteHistoryStore()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        syncHistory()
    }

    func updateSearchRegion(near coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 25_000,
            longitudinalMeters: 25_000
        )
    }

    func updateSearchText(_ text: String, near coordinate: CLLocationCoordinate2D?) {
        searchText = text
        updateSearchRegion(near: coordinate)
        errorMessage = ""

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completions = []
            isSearching = false
            return
        }

        isSearching = true
        completer.queryFragment = trimmed
    }

    func clearSearch() {
        searchText = ""
        completions = []
        isSearching = false
        errorMessage = ""
    }

    func clearRoute() {
        activeRoute = nil
        selectedDriveHistory = nil
        currentStepIndex = 0
        distanceToCurrentStepMeters = nil
        distanceToDestinationMeters = nil
        didArrive = false
        lockedCameraHeading = nil
        errorMessage = ""
        cameraMode = .forward
    }

    func toggleCameraMode() {
        cameraMode = cameraMode == .forward ? .overview : .forward
    }

    func setCameraMode(_ mode: DashNavigationCameraMode) {
        cameraMode = mode
    }

    var hasDisplayedRoute: Bool {
        activeRoute != nil || selectedDriveHistory != nil
    }

    var recentDriveSections: [DashDriveHistoryDaySection] {
        let grouped = Dictionary(grouping: driveHistory) { entry in
            Calendar.current.startOfDay(for: entry.startedAt)
        }

        return grouped
            .map { DashDriveHistoryDaySection(day: $0.key, entries: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
    }

    var currentStep: DashNavigationStep? {
        guard let activeRoute, !activeRoute.steps.isEmpty else { return nil }
        return activeRoute.steps[min(currentStepIndex, activeRoute.steps.count - 1)]
    }

    var followingStep: DashNavigationStep? {
        guard let activeRoute, currentStepIndex + 1 < activeRoute.steps.count else { return nil }
        return activeRoute.steps[currentStepIndex + 1]
    }

    var currentStepSymbolName: String {
        didArrive ? "flag.checkered" : (currentStep?.symbolName ?? "arrow.up")
    }

    var currentInstructionText: String {
        if didArrive {
            return "Arrived at \(activeRoute?.destinationTitle ?? "destination")"
        }
        return currentStep?.instructions ?? "Continue"
    }

    var currentDistanceText: String {
        if didArrive {
            return DashNavigationRoute.formatDistance(distanceToDestinationMeters)
        }
        return DashNavigationRoute.formatDistance(distanceToCurrentStepMeters ?? currentStep?.distanceMeters)
    }

    var remainingDistanceText: String {
        DashNavigationRoute.formatDistance(distanceToDestinationMeters ?? activeRoute?.distanceMeters)
    }

    var preferredCameraDistance: CLLocationDistance {
        let baseDistance = distanceToCurrentStepMeters ?? currentStep?.distanceMeters ?? 450
        return min(max(baseDistance * 2.2, 320), 900)
    }

    var cameraModeButtonTitle: String {
        cameraMode.label
    }

    var cameraModeButtonSymbolName: String {
        cameraMode.symbolName
    }

    @MainActor
    func planRouteFromCurrentQuery(origin: CLLocation?) async -> Bool {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Type a destination first."
            return false
        }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        if let coordinate = origin?.coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 25_000,
                longitudinalMeters: 25_000
            )
        }

        return await planRoute(using: request, origin: origin)
    }

    @MainActor
    func selectCompletion(_ completion: DashNavigationCompletion, origin: CLLocation?) async -> Bool {
        searchText = completion.title
        let request = MKLocalSearch.Request(completion: completion.result)
        return await planRoute(using: request, origin: origin)
    }

    @MainActor
    private func planRoute(using request: MKLocalSearch.Request, origin: CLLocation?) async -> Bool {
        guard let origin else {
            errorMessage = "Waiting for a GPS fix before planning a route."
            return false
        }

        isCalculatingRoute = true
        errorMessage = ""

        defer {
            isCalculatingRoute = false
        }

        do {
            let searchResponse = try await MKLocalSearch(request: request).start()
            guard let destination = searchResponse.mapItems.first else {
                errorMessage = "No destination matched that search."
                return false
            }

            let directionsRequest = MKDirections.Request()
            directionsRequest.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
            directionsRequest.destination = destination
            directionsRequest.transportType = .automobile
            directionsRequest.requestsAlternateRoutes = false

            let directionsResponse = try await MKDirections(request: directionsRequest).calculate()
            guard let route = directionsResponse.routes.first else {
                errorMessage = "No drivable route was found."
                return false
            }

            historyStore.recordDestination(destination)
            syncHistory()
            activeRoute = DashNavigationRoute(destination: destination, route: route, origin: origin.coordinate)
            selectedDriveHistory = nil
            currentStepIndex = 0
            didArrive = false
            cameraMode = .forward
            updateProgress(with: origin, fallbackHeading: validFallbackHeading(from: origin, headingDegrees: nil))
            completions = []
            return true
        } catch {
            errorMessage = "Couldn't calculate the route right now."
            return false
        }
    }

    func updateProgress(with location: CLLocation?, fallbackHeading: CLLocationDirection?) {
        guard let location else { return }

        updateSearchRegion(near: location.coordinate)

        guard let activeRoute else { return }

        distanceToDestinationMeters = location.distance(from: CLLocation(latitude: activeRoute.destinationCoordinate.latitude, longitude: activeRoute.destinationCoordinate.longitude))

        if currentStep != nil {
            while currentStepIndex < activeRoute.steps.count - 1 && shouldAdvance(from: location, past: stepForIndex(currentStepIndex)) {
                currentStepIndex += 1
            }
        }

        let step = currentStep
        distanceToCurrentStepMeters = step.map {
            location.distance(from: CLLocation(latitude: $0.endCoordinate.latitude, longitude: $0.endCoordinate.longitude))
        }

        if let distanceToDestinationMeters, distanceToDestinationMeters <= 30, currentStepIndex >= max(activeRoute.steps.count - 1, 0) {
            didArrive = true
        } else {
            didArrive = false
        }

        let liveHeading = validFallbackHeading(from: location, headingDegrees: fallbackHeading)
        lockedCameraHeading = liveHeading ?? step.map { $0.heading(from: location.coordinate) }
    }

    @MainActor
    func routeToRecentDestination(_ destination: DashRecentDestination, origin: CLLocation?) async -> Bool {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        mapItem.name = destination.title
        return await planRoute(to: mapItem, origin: origin)
    }

    func selectDriveHistory(_ entry: DashDriveHistoryEntry) {
        activeRoute = nil
        selectedDriveHistory = entry
        currentStepIndex = 0
        distanceToCurrentStepMeters = nil
        distanceToDestinationMeters = entry.distanceMeters
        didArrive = false
        lockedCameraHeading = nil
        cameraMode = .overview
        errorMessage = ""
    }

    func recordDriveLocation(_ location: CLLocation?) {
        guard let location else { return }
        historyStore.recordDriveLocation(location)
        syncHistory()
    }

    private func syncHistory() {
        recentDestinations = historyStore.recentDestinations
        driveHistory = historyStore.driveEntries.filter { $0.coordinates.count > 1 }
    }

    @MainActor
    private func planRoute(to destination: MKMapItem, origin: CLLocation?) async -> Bool {
        guard let origin else {
            errorMessage = "Waiting for a GPS fix before planning a route."
            return false
        }

        isCalculatingRoute = true
        errorMessage = ""

        defer {
            isCalculatingRoute = false
        }

        do {
            let directionsRequest = MKDirections.Request()
            directionsRequest.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
            directionsRequest.destination = destination
            directionsRequest.transportType = .automobile
            directionsRequest.requestsAlternateRoutes = false

            let directionsResponse = try await MKDirections(request: directionsRequest).calculate()
            guard let route = directionsResponse.routes.first else {
                errorMessage = "No drivable route was found."
                return false
            }

            historyStore.recordDestination(destination)
            syncHistory()
            activeRoute = DashNavigationRoute(destination: destination, route: route, origin: origin.coordinate)
            selectedDriveHistory = nil
            currentStepIndex = 0
            didArrive = false
            cameraMode = .forward
            updateProgress(with: origin, fallbackHeading: validFallbackHeading(from: origin, headingDegrees: nil))
            completions = []
            return true
        } catch {
            errorMessage = "Couldn't calculate the route right now."
            return false
        }
    }

    private func stepForIndex(_ index: Int) -> DashNavigationStep {
        activeRoute!.steps[min(index, activeRoute!.steps.count - 1)]
    }

    private func shouldAdvance(from location: CLLocation, past step: DashNavigationStep) -> Bool {
        let threshold = min(max(step.distanceMeters * 0.18, 22), 90)
        let stepEndLocation = CLLocation(latitude: step.endCoordinate.latitude, longitude: step.endCoordinate.longitude)
        return location.distance(from: stepEndLocation) <= threshold
    }

    private func validFallbackHeading(from location: CLLocation?, headingDegrees: CLLocationDirection?) -> CLLocationDirection? {
        if let location, location.course >= 0 {
            return location.course
        }
        return headingDegrees
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.isSearching = false
            self.completions = completer.results.map { DashNavigationCompletion(result: $0) }
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.isSearching = false
            self.completions = []
            self.errorMessage = "Search suggestions are unavailable right now."
        }
    }
}

struct DashNavigationSheet: View {
    @ObservedObject var navigation: DashNavigationModel
    let currentLocation: CLLocation?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                searchBar

                if let route = navigation.activeRoute {
                    activeRouteCard(route)
                }

                if !navigation.errorMessage.isEmpty {
                    Text(navigation.errorMessage)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if navigation.isSearching || navigation.isCalculatingRoute {
                    ProgressView(navigation.isCalculatingRoute ? "Calculating route..." : "Searching...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                suggestionsList
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .navigationTitle("Navigation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if navigation.hasDisplayedRoute {
                        Button("Clear route") {
                            navigation.clearRoute()
                        }
                    }
                }
            }
            .onAppear {
                navigation.updateSearchRegion(near: currentLocation?.coordinate)
                if navigation.searchText.isEmpty {
                    isSearchFieldFocused = true
                }
            }
        }
        .presentationDetents([.fraction(0.4), .large])
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Where do you want to go?", text: searchBinding)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFieldFocused)
                .onSubmit {
                    planRouteFromTypedQuery()
                }

            if !navigation.searchText.isEmpty {
                Button {
                    navigation.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var suggestionsList: some View {
        List {
            if let route = navigation.activeRoute, !route.steps.isEmpty {
                Section("Turns") {
                    ForEach(Array(route.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: 12) {
                            Image(systemName: step.symbolName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(index == navigation.currentStepIndex ? .blue : .secondary)
                                .frame(width: 26)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.instructions)
                                    .foregroundStyle(index == navigation.currentStepIndex ? .primary : .secondary)
                                Text(step.distanceText)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if index == navigation.currentStepIndex && !navigation.didArrive {
                                Text("Next")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.blue.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !navigation.recentDestinations.isEmpty && navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Recent destinations") {
                    ForEach(navigation.recentDestinations) { destination in
                        Button {
                            routeToRecentDestination(destination)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(destination.title)
                                if !destination.subtitle.isEmpty {
                                    Text(destination.subtitle)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Text(destination.timeText)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if !navigation.recentDriveSections.isEmpty && navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ForEach(navigation.recentDriveSections) { section in
                    Section(section.title) {
                        ForEach(section.entries) { drive in
                            Button {
                                navigation.selectDriveHistory(drive)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(drive.titleText)
                                    Text(drive.subtitleText)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }

            if !navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Search") {
                    Button {
                        planRouteFromTypedQuery()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Route to \"\(navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                            Text("Search this text directly and build a driving route.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(navigation.isCalculatingRoute)
                }
            }

            if !navigation.completions.isEmpty {
                Section("Suggestions") {
                    ForEach(navigation.completions) { completion in
                        Button {
                            planRoute(for: completion)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(completion.title)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if navigation.completions.isEmpty && navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Text("Search for a destination, reopen a recent route, or pick a saved drive from any day the app recorded location history.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func activeRouteCard(_ route: DashNavigationRoute) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(route.destinationTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))

                    if !route.destinationSubtitle.isEmpty {
                        Text(route.destinationSubtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(route.travelTimeText)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }

            if navigation.didArrive {
                Text("You have arrived • \(route.destinationLine)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(navigation.currentInstructionText) • in \(navigation.currentDistanceText)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }

            Text("\(navigation.remainingDistanceText) remaining • arrive \(route.arrivalTimeText)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { navigation.searchText },
            set: { navigation.updateSearchText($0, near: currentLocation?.coordinate) }
        )
    }

    private func planRouteFromTypedQuery() {
        Task {
            let didPlanRoute = await navigation.planRouteFromCurrentQuery(origin: currentLocation)
            if didPlanRoute {
                dismiss()
            }
        }
    }

    private func planRoute(for completion: DashNavigationCompletion) {
        Task {
            let didPlanRoute = await navigation.selectCompletion(completion, origin: currentLocation)
            if didPlanRoute {
                dismiss()
            }
        }
    }

    private func routeToRecentDestination(_ destination: DashRecentDestination) {
        Task {
            let didPlanRoute = await navigation.routeToRecentDestination(destination, origin: currentLocation)
            if didPlanRoute {
                dismiss()
            }
        }
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coordinates = Array(repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private extension MKMapRect {
    init(centeredAt coordinate: CLLocationCoordinate2D, meters: CLLocationDistance = 250) {
        let point = MKMapPoint(coordinate)
        let pointRadius = (meters * MKMapPointsPerMeterAtLatitude(coordinate.latitude)) / 2
        self.init(
            x: point.x - pointRadius,
            y: point.y - pointRadius,
            width: pointRadius * 2,
            height: pointRadius * 2
        )
    }
}

private extension CLLocationCoordinate2D {
    func bearing(to coordinate: CLLocationCoordinate2D) -> CLLocationDirection {
        let fromLatitude = latitude * .pi / 180
        let fromLongitude = longitude * .pi / 180
        let toLatitude = coordinate.latitude * .pi / 180
        let toLongitude = coordinate.longitude * .pi / 180

        let longitudeDelta = toLongitude - fromLongitude
        let y = sin(longitudeDelta) * cos(toLatitude)
        let x = cos(fromLatitude) * sin(toLatitude) - sin(fromLatitude) * cos(toLatitude) * cos(longitudeDelta)
        let bearing = atan2(y, x) * 180 / .pi

        return bearing >= 0 ? bearing : bearing + 360
    }
}
