# Ray-Ban Agents

A SwiftUI iOS application that integrates Ray-Ban Meta smart glasses with Stream Video SDK and [Vision Agents](https://github.com/GetStream/Vision-Agents). This project allows video streaming from Ray-Ban smart glasses to video calls, with support for backend AI agents that can join calls and process the video feed.


- Stream video from Ray-Ban Meta smart glasses camera
- Audio routing from glasses microphone to Stream Video calls
- Integration with backend vision agents API

## Prerequisites

- Xcode 26.3 or a compatible newer Xcode
- iOS 26.2 or later
- Ray-Ban Meta smart glasses
- Stream Video account ([Get one here](https://getstream.io))
- Meta Wearables Developer account

## SDK Versions

- Stream Video Swift SDK: `1.48.0` or newer compatible `1.x`
- Meta Wearables DAT iOS SDK: `0.8.0` or newer compatible `0.x`

## Setup

### 1. Clone the Vision Agents Repository

First, clone and set up the vision agents backend server:

```bash
git clone https://github.com/GetStream/Vision-Agents.git
cd Vision-Agents
# Follow the setup instructions in that repository
```

### 2. Configure Secrets

1. Copy the secrets template file:
```bash
cp rayban_agents/Secrets.swift.template rayban_agents/Secrets.swift
```

2. Edit `Secrets.swift` and fill in your credentials:

```swift
enum Secrets {
    // Stream Video credentials from https://dashboard.getstream.io
    static let streamApiKey = "YOUR_STREAM_API_KEY"
    static let streamUserToken = "YOUR_USER_TOKEN"
    static let streamUserId = "YOUR_USER_ID"

    // Meta Wearables App ID (use "0" for Developer Mode)
    static let metaAppId = "YOUR_META_APP_ID"

    // Vision Agents backend
    static let backendBaseURL: String? = "http://127.0.0.1:8000"
    static let backendSessionsPath: String? = "/sessions"
    static let backendUserId: String? = nil

    // Hardcoded call ID for testing - use the same ID when starting the agent
    static let fixedCallId: String? = "test-call-123"
}
```

### 3. Configure Call ID

The app uses a hardcoded call ID for testing. Make sure the `fixedCallId` in `Secrets.swift` matches the call ID you'll use when triggering the agent to join:

```swift
static let fixedCallId: String? = "test-call-123"
```

When starting your backend agent, use the same call ID so it can join the correct call.


### 4. Start the Backend Server

For this project, the call ID is hardcoded so pick an example (plugins/gemini/example) and ensure you update the call ID for the agent to match your project. Run the example with `uv run <example> run`. On the iOS side, once the server is running, start the app in Xcode and then hit Join call.

```bash
cd Vision-Agents
# Start the server (follow the specific instructions in that repo)
 uv run plugins/gemini/example/gemini_vlm_agent_example.py run
```

## Running the Project

1. Open `rayban_agents.xcodeproj` in Xcode
2. Select your target device (iPhone with Ray-Ban glasses paired via Bluetooth)
3. Build and run the project (Cmd+R)
4. Connect your Ray-Ban Meta smart glasses via Bluetooth
5. Start a call in the app
6. The backend agent should automatically join the call and begin processing video

## Project Structure

```
rayban_agents/
├── Managers/
│   ├── StreamCallManager.swift      # Stream Video SDK integration
│   └── WearablesManager.swift       # Ray-Ban glasses connection
├── Views/
│   ├── ContentView.swift            # Main app view
│   ├── CallView.swift               # Call interface
│   ├── CallControlsView.swift       # Call control buttons
│   └── ConnectionStatusView.swift   # Connection status display
├── Filters/
│   └── WearableVideoFilter.swift    # Replaces Stream camera frames with wearable frames
└── Secrets.swift                    # Configuration (git-ignored)
```

## Troubleshooting

### Agent Not Joining Call
- Verify the backend server is running and accessible
- Check that `backendBaseURL` in Secrets.swift is correct
- Ensure the call ID matches between the app and backend
- Review backend server logs for connection errors

### No Video from Glasses
- Confirm Ray-Ban glasses are paired and connected via Bluetooth
- Check camera permissions in iOS Settings
- Verify Meta Wearables app is installed and configured

### Audio Issues
- Ensure Bluetooth audio routing is enabled
- Check iOS audio settings for preferred input device
- Verify microphone permissions
