//
//  DashCamView.swift
//  DashCam
//
//  Created by Muhanned Alkhafaji on 3/1/26.
//

import SwiftUI

// main dashcam screen

// this file now holds only the on screen dashcam view layer

// camera session logic, recording logic, support types, clips browser, and settings screen all live in other files now

// keep this file focused on layout, buttons, sheets, and status display

struct DashCamView: View {
    
    // main controller
    
    // this owns the camera session, recorder, loop logic, speed logic, and every piece of live app state the UI reads
    
    @StateObject private var camera = DashCamController()
    
    // clips sheet toggle
    
    // this opens the in app clip browser/player screen
    
    @State private var showingClips = false
    
    // settings sheet toggle
    
    // this opens the dedicated settings screen so the main camera screen stays clean
    
    @State private var showingSettings = false
    
    // scene phase
    
    // this lets the view tell the controller when the app leaves or returns to the foreground
    
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        GeometryReader { geometry in
            
            // simple orientation check for layout only
            
            // this does not drive camera rotation, only whether the controls stack as landscape or portrait
            
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                
                // full screen background so there is never white behind the preview
                
                Color.black.ignoresSafeArea()
                
                // rear camera preview
                
                // this is the main live camera feed and always sits behind everything else
                
                RearCameraPreview(controller: camera)
                    .ignoresSafeArea()
                
                // optional front pip preview
                
                // this only shows when the controller has a current front camera image and the setting is enabled
                
                if camera.showFrontPreview, let image = camera.frontPreviewImage {
                    frontPreview(image: image, isLandscape: isLandscape)
                }

                if camera.showCompass, let compassText = camera.compassText {
                    compassOverlay(text: compassText)
                }
                
                // overlay layout
                
                // keep the overlay layout separate for landscape vs portrait so the main body stays readable
                
                if isLandscape {
                    landscapeOverlay
                } else {
                    portraitOverlay
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                camera.captureRearPhoto()
            }
        }
        .preferredColorScheme(.dark)
        
        // start camera services when the view appears
        
        .onAppear {
            camera.start()
        }
        
        // stop camera services when the view disappears
        
        .onDisappear {
            camera.stop()
        }
        
        // forward foreground/background changes to the controller
        
        .onChange(of: scenePhase) { _, newPhase in
            camera.handleScenePhaseChange(newPhase)
        }
        
        // clips browser sheet
        
        .sheet(isPresented: $showingClips) {
            DashCamClipsView()
        }
        
        // settings sheet
        
        .sheet(isPresented: $showingSettings) {
            DashCamSettingsView(camera: camera)
        }
        
        // shared alert driven by the controller
        
        .alert("DashCam", isPresented: $camera.showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.alertMessage)
        }
    }

    private func compassOverlay(text: String) -> some View {
        VStack {
            HStack {
                Text(text)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55))
                    .clipShape(Capsule())

                Spacer()
            }

            Spacer()
        }
        .padding(.top, 72)
        .padding(.leading, 16)
        .allowsHitTesting(false)
    }
    
    // front preview
    
    // this is the small front camera pip shown over the rear preview when enabled
    
    @ViewBuilder
    private func frontPreview(image: UIImage, isLandscape: Bool) -> some View {
        VStack {
            HStack {
                Spacer()
                
                ZStack(alignment: .topLeading) {
                    
                    // front image itself
                    
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: isLandscape ? 210 : 150, height: isLandscape ? 140 : 190)
                        .clipped()
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(.white.opacity(0.35), lineWidth: 1)
                        )
                    
                    // small front badge
                    
                    Text("front")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.72))
                        .clipShape(Capsule())
                        .padding(8)
                }
            }
            Spacer()
        }
        .padding(.top, isLandscape ? 20 : 95)
        .padding(.trailing, 16)
        .allowsHitTesting(false)
    }
    
    // landscape overlay
    
    // in landscape the status stack stays on the left and the buttons stay on the right
    
    private var landscapeOverlay: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                topInfo
                Spacer()
                if camera.showMainExtraInfo {
                    bottomInfo
                }
            }
            .padding(.leading, 16)
            .padding(.top, 16)
            .padding(.bottom, 20)
            
            Spacer()
            
            VStack(spacing: 14) {
                Spacer()
                HStack(spacing: 12) {
                    clipsButton
                    recordButton
                    settingsButton
                }
            }
            .padding(.trailing, 16)
            .padding(.bottom, 20)
        }
    }
    
    // portrait overlay
    
    // in portrait the status goes at the top and the controls + record button sit at the bottom
    
    private var portraitOverlay: some View {
        VStack(spacing: 0) {
            topInfo
                .padding(.horizontal, 16)
                .padding(.top, 16)
            
            Spacer()
            
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    clipsButton
                    recordButton
                    settingsButton
                }
                if camera.showMainExtraInfo {
                    bottomInfo
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }
    
    // top status info
    
    // keep the live stamp always visible and make the older status rows optional
    
    private var topInfo: some View {
        VStack(spacing: 10) {
            if camera.showMainStatusBadges {
                HStack(spacing: 10) {
                    
                    // main status chip
                    
                    Text(camera.statusText)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(camera.statusColor)
                        .clipShape(Capsule())
                    
                    // multicam capability chip
                    
                    if camera.multiCamSupported {
                        Text("MULTICAM")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.blue.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    
                    Spacer()
                }
            }
            
            infoRow(camera.liveStampText)

            if camera.detailText == "Rear photo saved locally." {
                infoRow(camera.detailText)
            }

            if camera.showMainExtraInfo {
                if camera.detailText != "Rear photo saved locally." {
                    infoRow(camera.detailText)
                }
                infoRow(camera.savedClipText)
                infoRow(camera.loopStatusText)
                infoRow(camera.speedStatusText)
            }
        }
        .frame(maxWidth: 520)
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
            showingClips = true
        } label: {
            controlIcon(systemImage: "film.stack")
        }
    }

    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            controlIcon(systemImage: "gearshape")
        }
    }

    private func controlIcon(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 54, height: 54)
            .background(.black.opacity(0.55))
            .clipShape(Circle())
    }
    
    // record button
    
    // this is still the main manual start / stop loop recording control
    
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
