# DashCam
An iOS dashcam app

## Convoy Live Map (friends on map)

### 1) Run the temporary server on your Mac

```bash
cd /Users/x/Desktop/DashCam/server
npm install
npm start
```

Server default endpoint:

`ws://127.0.0.1:8787`

### 2) Configure app settings

In DashCam Settings -> Convoy:

- Enable convoy live map: `ON`
- Server URL:
  - iOS simulator on same Mac: `ws://127.0.0.1:8787`
  - physical iPhone: use a public tunnel URL (recommended `wss://...`)
- Session code: any shared code (example: `test-drive`)
- Display name: your driver label

### 3) Connect multiple devices

- Put every friend on the same Server URL and Session code.
- Each device will show the others as live car markers on map mode.

### 4) Tunnel for physical phones (optional but recommended)

You can expose your local server with a tunnel (example: ngrok) and then set the app Server URL to the tunnel `wss://...` URL.
