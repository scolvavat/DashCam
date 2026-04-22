//
//  DashCamView.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import SwiftUI
import MapKit
import Network
import Combine

enum DashClipPresentation: Identifiable {
    case library
    case drive(DashDriveHistoryEntry)

    var id: String {
        switch self {
        case .library:
            return "library"
        case .drive(let drive):
            return "drive-\(drive.id)"
        }
    }
}

// main dashcam screen

// this file now holds only the on screen dashcam view layer

// camera session logic, recording logic, support types, clips browser, and settings screen all live in other files now

// keep this file focused on layout, buttons, sheets, and status display

struct DashCamView: View {
    
    // main controller
    
    // this owns the camera session, recorder, loop logic, speed logic, and every piece of live app state the UI reads
    
    @StateObject private var camera = DashCamController()
    @StateObject private var networkMonitor = DashNetworkMonitor()
    @StateObject private var navigation = DashNavigationModel()
    
    // clips sheet toggle
    
    // this opens the in app clip browser/player screen
    
    @State private var presentedClipScope: DashClipPresentation?
    
    // settings sheet toggle
    
    // this opens the dedicated settings screen so the main camera screen stays clean
    
    @State private var showingSettings = false
    @State private var showingNavigation = false
    
    // scene phase
    
    // this lets the view tell the controller when the app leaves or returns to the foreground
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var mapPosition: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var showingLaunchOverlay = true
    @State private var hasStartedInitialBootstrap = false
    @State private var launchOverlayStartedAt = Date()
    @State private var hasScheduledLaunchOverlayDismissal = false
    
    var body: some View {
        GeometryReader { geometry in
            
            // simple orientation check for layout only
            
            // this does not drive camera rotation, only whether the controls stack as landscape or portrait
            
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                
                // full screen background so there is never white behind the preview
                
                Color.black.ignoresSafeArea()

                mainBackground
                
                // overlay layout
                
                // keep the overlay layout separate for landscape vs portrait so the main body stays readable
                
                overlay(for: isLandscape)

                if shouldShowLaunchOverlay {
                    launchOverlay
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !camera.showMapBackground, !shouldShowLaunchOverlay else { return }
                camera.captureRearPhoto()
            }
        }
        .preferredColorScheme(.dark)
        
        // start camera services when the view appears
        
        .onAppear {
            beginInitialStartupIfNeeded()
        }
        
        // stop camera services when the view disappears
        
        .onDisappear {
            camera.stop()
        }
        
        // forward foreground/background changes to the controller
        
        .onChange(of: scenePhase) { _, newPhase in
            camera.handleScenePhaseChange(newPhase)
        }
        .onChange(of: camera.showMapBackground) { _, isMapEnabled in
            if isMapEnabled {
                if !showingLaunchOverlay {
                    updateMapPosition()
                }
            }
        }
        .onChange(of: camera.isRunning) { _, isRunning in
            if isRunning {
                dismissLaunchOverlayIfNeeded()
                if camera.showMapBackground {
                    updateMapPosition()
                }
            }
        }
        .onChange(of: camera.showAlert) { _, isShowingAlert in
            if isShowingAlert {
                showingLaunchOverlay = false
            }
        }
        .onReceive(camera.locationManager.$headingDegrees) { headingDegrees in
            guard camera.showMapBackground else { return }
            if navigation.activeRoute != nil {
                navigation.updateProgress(
                    with: camera.locationManager.latestLocation,
                    fallbackHeading: fallbackHeading(for: camera.locationManager.latestLocation, headingDegrees: headingDegrees)
                )
            }
            updateMapPosition()
        }
        .onReceive(camera.locationManager.$currentCoordinate) { coordinate in
            navigation.updateSearchRegion(near: coordinate)
        }
        .onReceive(camera.locationManager.$latestLocation) { location in
            navigation.recordDriveLocation(location)
            navigation.updateProgress(
                with: location,
                fallbackHeading: fallbackHeading(for: location, headingDegrees: camera.locationManager.headingDegrees)
            )
            guard camera.showMapBackground, navigation.hasDisplayedRoute else { return }
            updateMapPosition()
        }
        .onReceive(navigation.$activeRoute) { route in
            camera.updateActiveRouteContext(
                title: route?.destinationTitle,
                subtitle: route?.destinationSubtitle
            )
            guard camera.showMapBackground else { return }
            updateMapPosition()
        }
        .onReceive(navigation.$selectedDriveHistory) { _ in
            guard camera.showMapBackground else { return }
            updateMapPosition()
        }
        .onReceive(navigation.$cameraMode) { _ in
            guard camera.showMapBackground else { return }
            updateMapPosition()
        }
        
        // clips browser sheet
        
        .sheet(item: $presentedClipScope) { scope in
            DashCamClipsView(scope: scope)
        }
        
        // settings sheet
        
        .sheet(isPresented: $showingSettings) {
            DashCamSettingsView(camera: camera)
        }

        .sheet(isPresented: $showingNavigation) {
            DashNavigationSheet(
                navigation: navigation,
                currentLocation: camera.locationManager.latestLocation
            )
        }
        
        // shared alert driven by the controller
        
        .alert("DashCam", isPresented: $camera.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.alertMessage)
        }
    }

    private var mainBackground: some View {
        Group {
            if shouldShowMapBackground {
                dashMapBackground
            } else {
                RearCameraPreview(controller: camera)
            }
        }
        .ignoresSafeArea()
    }

    private var shouldShowMapBackground: Bool {
        camera.showMapBackground && !showingLaunchOverlay
    }

    private var shouldShowLaunchOverlay: Bool {
        showingLaunchOverlay
    }

    private var launchOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.96),
                    Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.9),
                    Color(red: 0.16, green: 0.06, blue: 0.05).opacity(0.82)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 18) {
                Spacer()

                Image("LaunchBrandIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 10)

                VStack(spacing: 8) {
                    Text("Opening DashCam")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(launchOverlayDetailText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.76))
                }

                Spacer()

                VStack(spacing: 10) {
                    Capsule()
                        .fill(.white.opacity(0.14))
                        .frame(width: 176, height: 6)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .frame(width: camera.isRunning ? 176 : 104, height: 6)
                        }

                    Text(launchOverlayFootnoteText)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.68))
                }
                .padding(.bottom, 52)
            }
            .padding(.horizontal, 24)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private var launchOverlayDetailText: String {
        if camera.isRunning {
            return "Rear camera is live. Finishing warm-up..."
        }

        let trimmedDetail = camera.detailText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDetail.isEmpty ? "Preparing live camera and controls..." : trimmedDetail
    }

    private var launchOverlayFootnoteText: String {
        if camera.isRunning {
            return "Background services continue after first paint"
        }

        return "Showing the shell first so the app feels instant"
    }

    private var dashMapBackground: some View {
        Map(position: $mapPosition, interactionModes: mapInteractionModes) {
            UserAnnotation()

            if camera.locationManager.breadcrumbCoordinates.count > 1 {
                MapPolyline(coordinates: camera.locationManager.breadcrumbCoordinates)
                    .stroke(.cyan.opacity(0.85), lineWidth: 4)
            }

            if let route = navigation.activeRoute, route.routeCoordinates.count > 1 {
                MapPolyline(coordinates: route.routeCoordinates)
                    .stroke(.blue.opacity(0.92), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }

            if let drive = navigation.selectedDriveHistory, drive.coordinates.count > 1 {
                MapPolyline(coordinates: drive.coordinates)
                    .stroke(.green.opacity(0.88), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round, dash: [10, 8]))
            }

            ForEach(camera.convoyFriends) { friend in
                Annotation(friend.name, coordinate: friend.coordinate) {
                    friendMarker(friend)
                }
            }

            if let route = navigation.activeRoute {
                Annotation(route.destinationTitle, coordinate: route.destinationCoordinate) {
                    destinationMarker(route)
                }
            } else if let drive = navigation.selectedDriveHistory, let endCoordinate = drive.coordinates.last {
                Annotation("Saved drive", coordinate: endCoordinate) {
                    savedDriveMarker(drive)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func friendMarker(_ friend: DashFriendPresence) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "car.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.blue.opacity(0.9))
                .clipShape(Circle())

            Text(friend.name)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.65))
                .clipShape(Capsule())
        }
    }

    private func destinationMarker(_ route: DashNavigationRoute) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "flag.checkered.circle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white, .green)
                .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 3)

            Text(route.destinationTitle)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.7))
                .clipShape(Capsule())
        }
    }

    private func savedDriveMarker(_ drive: DashDriveHistoryEntry) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90.circle.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white, .green)
                .shadow(color: .black.opacity(0.25), radius: 5, x: 0, y: 3)

            Text(drive.titleText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.7))
                .clipShape(Capsule())
        }
    }

    private func overlay(for isLandscape: Bool) -> some View {
        Group {
            if isLandscape {
                HStack(spacing: 0) {
                    overlayInfoStack
                        .padding(.leading, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    Spacer()

                    VStack(spacing: 14) {
                        Spacer()
                        controlsLayout(for: true)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 20)
                }
            } else {
                VStack(spacing: 0) {
                    topInfo
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    Spacer()

                    VStack(spacing: 14) {
                        controlsLayout(for: false)
                        if camera.showMainExtraInfo {
                            bottomInfo
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var overlayInfoStack: some View {
        VStack(spacing: 12) {
            topInfo
            Spacer()
            if camera.showMainExtraInfo {
                bottomInfo
            }
        }
    }
    
    // top status info
    
    // keep the live stamp always visible and make the older status rows optional
    
    private var topInfo: some View {
        VStack(spacing: 10) {
            if navigation.activeRoute != nil {
                navigationBanner
                navigationCameraModeButton
            }
            ForEach(topInfoRows, id: \.self) { row in
                infoRow(row)
            }
        }
        .frame(maxWidth: 520)
    }

    private var topInfoRows: [String] {
        var rows = [camera.liveStampText]

        if shouldShowLaunchOverlay {
            rows.append(camera.isRunning ? "Camera ready. Removing launch shell..." : "Opening camera in background...")
        }

        if camera.showMapBackground, !networkMonitor.isOnline {
            rows.append("Offline mode • using cached map tiles")
        }

        if camera.showMapBackground {
            rows.append(camera.convoyStatusText)
        }

        if navigation.selectedDriveHistory != nil {
            rows.append("Saved drive selected • clips button filters to this drive")
        }

        if camera.detailText == "Rear photo saved locally." {
            rows.append(camera.detailText)
        }

        if camera.showMainExtraInfo {
            if camera.detailText != "Rear photo saved locally." {
                rows.append(camera.detailText)
            }
            rows.append(contentsOf: [camera.savedClipText, camera.loopStatusText, camera.speedStatusText])
        }

        return rows
    }
    
    // bottom info row
    
    // keep one short build description on screen so you know what version of the UI path you are looking at
    
    private var bottomInfo: some View {
        infoRow("split ui build • main view only • clips + settings moved out")
            .frame(maxWidth: 520)
    }
    
    // reusable text row
    
    // this keeps every status row visually consistent
    
    private func infoRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    
    private var clipsButton: some View {
        Button {
            if let drive = navigation.selectedDriveHistory {
                presentedClipScope = .drive(drive)
            } else {
                presentedClipScope = .library
            }
        } label: {
            controlIcon(systemImage: "film.stack")
                .overlay(alignment: .topTrailing) {
                    if navigation.selectedDriveHistory != nil {
                        Circle()
                            .fill(.green)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(.black.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
        }
    }

    private func controlsLayout(for isLandscape: Bool) -> some View {
        Group {
            if isLandscape {
                HStack(spacing: 12) {
                    clipsButton
                    eventButton
                    recordButton
                    navigationButton
                    settingsButton
                }
            } else {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        clipsButton
                        navigationButton
                        settingsButton
                    }

                    HStack(spacing: 16) {
                        eventButton
                        recordButton
                    }
                }
            }
        }
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            controlIcon(systemImage: "gearshape")
        }
    }

    private var navigationButton: some View {
        Button {
            if !camera.showMapBackground {
                camera.showMapBackground = true
            }
            showingNavigation = true
        } label: {
            controlIcon(systemImage: navigation.activeRoute == nil ? "map" : "map.fill")
                .overlay(alignment: .topTrailing) {
                    if navigation.activeRoute != nil {
                        Circle()
                            .fill(.blue)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(.black.opacity(0.35), lineWidth: 1)
                            )
                    }
                }
        }
    }

    private var eventButton: some View {
        Button {
            camera.saveCurrentMoment()
        } label: {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(camera.isRecording ? .black : .white)
                .frame(width: 54, height: 54)
                .background(camera.isRecording ? Color.yellow : .black.opacity(0.55))
                .clipShape(Circle())
        }
        .disabled(!camera.isRecording)
        .opacity(camera.isRecording ? 1 : 0.45)
    }

    private func controlIcon(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(.black.opacity(0.55))
            .clipShape(Circle())
    }

    private func updateMapPosition() {
        if let route = navigation.activeRoute {
            if navigation.cameraMode == .overview {
                mapPosition = .rect(route.cameraRect)
            } else if let currentCoordinate = camera.locationManager.currentCoordinate {
                mapPosition = .camera(
                    MapCamera(
                        centerCoordinate: currentCoordinate,
                        distance: navigation.preferredCameraDistance,
                        heading: navigation.lockedCameraHeading ?? 0,
                        pitch: 0
                    )
                )
            } else {
                mapPosition = .rect(route.cameraRect)
            }
        } else if let drive = navigation.selectedDriveHistory {
            mapPosition = .rect(drive.cameraRect)
        } else {
            mapPosition = .userLocation(followsHeading: false, fallback: .automatic)
        }
    }

    private func beginInitialStartupIfNeeded() {
        guard !hasStartedInitialBootstrap else { return }
        hasStartedInitialBootstrap = true
        launchOverlayStartedAt = Date()

        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(180))
            camera.start()
        }
    }

    private func dismissLaunchOverlayIfNeeded() {
        guard showingLaunchOverlay else { return }
        guard !hasScheduledLaunchOverlayDismissal else { return }

        hasScheduledLaunchOverlayDismissal = true
        let elapsed = Date().timeIntervalSince(launchOverlayStartedAt)
        let remainingDelay = max(0, 0.85 - elapsed)
        let delayNanoseconds = UInt64(remainingDelay * 1_000_000_000)

        Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            withAnimation(.easeOut(duration: 0.24)) {
                showingLaunchOverlay = false
            }
        }
    }

    private var mapInteractionModes: MapInteractionModes {
        navigation.hasDisplayedRoute ? [.pan, .zoom] : [.pan, .zoom, .rotate]
    }

    private var navigationBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: navigation.currentStepSymbolName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(.blue.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                Text(navigation.currentInstructionText)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(navigationBannerSubtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text(navigation.currentDistanceText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text(navigation.remainingDistanceText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var navigationCameraModeButton: some View {
        Button {
            navigation.toggleCameraMode()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: navigation.cameraModeButtonSymbolName)
                    .font(.system(size: 13, weight: .bold))

                Text(navigation.cameraModeButtonTitle)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.black.opacity(0.62))
            .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var navigationBannerSubtitle: String {
        if navigation.didArrive {
            return navigation.activeRoute?.destinationLine ?? "Destination reached"
        }

        if navigation.cameraMode == .overview {
            return "Overview mode • tap Forward to re-center"
        }

        if let followingInstruction = navigation.followingStep?.instructions {
            return "Then \(followingInstruction.lowercased())"
        }

        return "Forward view • map auto rotates with your direction"
    }

    private func fallbackHeading(for location: CLLocation?, headingDegrees: CLLocationDirection?) -> CLLocationDirection? {
        if let location, location.course >= 0 {
            return location.course
        }
        return headingDegrees
    }
    
    // record button
    
    // The button now fronts two different controller states:
    // 1. idle with buffer armed: tapping promotes the hidden rolling minute into
    //    a protected recording session and then keeps recording forward.
    // 2. active saved recording: tapping closes that protected session but keeps
    //    the background buffer alive so the next tap can retro-save again.

    private var recordButton: some View {
        Button {
            camera.toggleRecording()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    
                    // outer button shell
                    
                    Circle()
                        .fill(camera.isRecording ? Color.red : Color.white)
                        .frame(width: 78, height: 78)
                    
                    // inner icon changes based on state
                    
                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 44, height: 44)
                    }
                }
                
                
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 18))
        }
        .disabled(!camera.canRecord)
        .opacity(camera.canRecord ? 1 : 0.6)
    }
}

// network monitor

// this is lightweight and only drives a small offline map hint on the main screen

final class DashNetworkMonitor: ObservableObject {
    @Published var isOnline: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dashcam.network.monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
